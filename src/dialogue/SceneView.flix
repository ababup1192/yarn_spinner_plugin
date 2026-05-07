/// Yarn → Scene 統合のための view 側 handler 一式。
///
/// `Dialogue.DialogueView` の本番（Scene 統合用）handler と、
/// 蓄積されたイベントを 1 フレーム単位で取り出す `Inbox` effect を
/// セットで提供する。両者は内部の同じ `MutDeque` を介して受け渡す。
///
/// 設計の意図:
///   - 受信ハンドラ（DialogueView）は scene を直接いじらず queue に push するだけ
///   - 消費は `Inbox.takeAll` を `process` ライフサイクル内で呼ぶ
///   - これにより `handleInput` が返すシーンと「side channel で書き込まれたシーン」
///     がマージされる必要がなくなる（pull 型）
///
/// `withSceneView(rc, body)` は queue 確保と両 handler 連結を内包し、
/// 呼び出し側に queue を露出しない。
mod Dialogue.SceneView {
    use Dialogue.ViewEvent
    use Dialogue.ViewEvent.{Line, Choices, Dismiss, Command, Complete}

    /// SceneView が貯めた `ViewEvent` を取り出す effect。
    /// `process` の中で呼ばれ、handler 側が region 内 `MutDeque` を List に変換して返す。
    /// gameLoop に scene 操作を漏らさず、フレーム毎の queue 消化を Node ライフサイクルに閉じる。
    pub eff Inbox {
        def takeAll(): List[ViewEvent]
    }

    /// `DialogueView` と `Inbox` を 1 つの `MutDeque` で繋ぐ handler セット。
    /// queue は内部で region に確保するので呼び出し側は触らない。
    pub def withSceneView(rc: Region[r], body: Unit -> a \ ef):
                           a \ (ef - Dialogue.DialogueView - Inbox) + r =
        let queue: MutDeque[ViewEvent, r] = MutDeque.empty(rc);
        run body() with handler Dialogue.DialogueView {
            def presentLine(line, resume) = {
                MutDeque.pushBack(Line(line#text, line#speaker), queue);
                resume()
            }
            def presentChoices(choices, resume) = {
                let labels = List.map(choice -> choice#text, choices);
                MutDeque.pushBack(Choices(labels), queue);
                resume()
            }
            def dismissLine(resume) = {
                MutDeque.pushBack(Dismiss, queue);
                resume()
            }
            def runCommand(commandText, resume) = {
                MutDeque.pushBack(Command(commandText), queue);
                resume()
            }
            def dialogueComplete(resume) = {
                MutDeque.pushBack(Complete, queue);
                resume()
            }
        } with handler Inbox {
            def takeAll(resume) = resume(takeAllInner(queue, Nil))
        }

    /// MutDeque から先頭 → 末尾の順で全要素を取り出して List で返す（破壊的）。
    def takeAllInner(queue: MutDeque[ViewEvent, r], acc: List[ViewEvent]):
                  List[ViewEvent] \ r =
        match MutDeque.popFront(queue) {
            case Some(event) => takeAllInner(queue, event :: acc)
            case None        => List.reverse(acc)
        }
}
