/// テスト用の `DialogueView` 実装。受け取った操作をログに蓄積する。
///
/// テスト本体に `run ... with handler DialogueView { ... }` を直書きしないよう、
/// effect 多相な `withRecordingView` を集約している。
mod Dialogue.StubView {

    /// view が受け取った 1 回分の操作。タプル比較しやすいように record でなく enum で表す。
    pub enum ViewEvent with Eq, ToString {
        case PresentedLine(String)
        case PresentedOptions(List[String])
        case Dismissed
        case Command(String)
        case Complete
    }

    /// view 操作を region 内 MutDeque に蓄積し、body 終了時に List で返す。
    /// 他の effect は `ef` で透過する。
    pub def withRecordingView(rc: Region[r], body: Unit -> a \ ef + Dialogue.DialogueView):
                                (a, List[ViewEvent]) \ ef + r =
        let log: MutDeque[ViewEvent, r] = MutDeque.empty(rc);
        let result = run body() with handler Dialogue.DialogueView {
            def presentLine(line, resume) = {
                MutDeque.pushBack(ViewEvent.PresentedLine(line#text), log);
                resume()
            }
            def presentOptions(options, resume) = {
                let texts = List.map(option -> option#text, options);
                MutDeque.pushBack(ViewEvent.PresentedOptions(texts), log);
                resume()
            }
            def dismissLine(resume) = {
                MutDeque.pushBack(ViewEvent.Dismissed, log);
                resume()
            }
            def runCommand(commandText, resume) = {
                MutDeque.pushBack(ViewEvent.Command(commandText), log);
                resume()
            }
            def dialogueComplete(resume) = {
                MutDeque.pushBack(ViewEvent.Complete, log);
                resume()
            }
        };
        (result, MutDeque.toList(log))
}
