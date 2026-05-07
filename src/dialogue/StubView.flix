/// テスト用の `DialogueView` 実装。受け取った操作を `Dialogue.ViewEvent` の
/// ログに蓄積する。
///
/// テスト本体に `run ... with handler DialogueView { ... }` を直書きしないよう、
/// effect 多相な `withRecordingView` を集約している。
mod Dialogue.StubView {
    use Dialogue.ViewEvent
    use Dialogue.ViewEvent.{Line, Choices, Dismiss, Command, Complete}

    /// view 操作を region 内 MutDeque に蓄積し、body 終了時に List で返す。
    /// 他の effect は `ef` で透過する。
    pub def withRecordingView(rc: Region[r], body: Unit -> a \ ef + Dialogue.DialogueView):
                                (a, List[ViewEvent]) \ ef + r =
        let log: MutDeque[ViewEvent, r] = MutDeque.empty(rc);
        let result = run body() with handler Dialogue.DialogueView {
            def presentLine(line, resume) = {
                MutDeque.pushBack(Line(line#text, line#speaker), log);
                resume()
            }
            def presentChoices(choices, resume) = {
                let labels = List.map(choice -> choice#text, choices);
                MutDeque.pushBack(Choices(labels), log);
                resume()
            }
            def dismissLine(resume) = {
                MutDeque.pushBack(Dismiss, log);
                resume()
            }
            def runCommand(commandText, resume) = {
                MutDeque.pushBack(Command(commandText), log);
                resume()
            }
            def dialogueComplete(resume) = {
                MutDeque.pushBack(Complete, log);
                resume()
            }
        };
        (result, MutDeque.toList(log))
}
