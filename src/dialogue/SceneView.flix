/// `Dialogue.DialogueView` の本番（Scene 統合用）handler。
///
/// 受け取ったイベントは `MutDeque[ViewEvent, r]` にそのまま貯めるだけで、
/// シーンの書き換えは行わない。`gameLoop` が毎フレーム
/// `DialogueScene.drainEvents` でキューを消化してシーンに反映する。
///
/// `Dialogue.StubView.withRecordingView` と同じ「録画」スタイルの handler だが、
/// 本モジュールはキューを呼び出し側に渡してもらい、フレーム単位で消化できるよう
/// にした点が異なる（`withRecordingView` は body 終了時に `List` で返してしまう）。
mod Dialogue.SceneView {
    use Dialogue.StubView.ViewEvent
    use Dialogue.StubView.ViewEvent.{PresentedLine, PresentedOptions, Dismissed, Command, Complete}

    /// `DialogueView` を実装する handler。
    ///
    /// `queue` は呼び出し側で region に確保した MutDeque。本 handler はここに
    /// `pushBack` するだけで、次フレームの `drainEvents` で消化される。
    pub def withSceneView(_rc: Region[r],
                          queue: MutDeque[ViewEvent, r],
                          body: Unit -> a \ ef + Dialogue.DialogueView):
                            a \ ef + r =
        run body() with handler Dialogue.DialogueView {
            def presentLine(line, resume) = {
                MutDeque.pushBack(PresentedLine(line#text), queue);
                resume()
            }
            def presentOptions(options, resume) = {
                let texts = List.map(option -> option#text, options);
                MutDeque.pushBack(PresentedOptions(texts), queue);
                resume()
            }
            def dismissLine(resume) = {
                MutDeque.pushBack(Dismissed, queue);
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
        }
}
