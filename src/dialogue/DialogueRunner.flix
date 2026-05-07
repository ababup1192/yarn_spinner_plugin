/// `Dialog` effect の実装。VM を駆動して、Waiting* に到達したら
/// `DialogueView` の対応する操作を呼ぶ。
///
/// 内部状態は呼び出し元から渡された region に閉じる：
///   - `vmRef`         現在の VM（Option：未開始は None）
///
/// 1 つの `submit*` 呼び出しは「VM に状態変化を流し込み、次の Waiting* / 完了
/// まで step を回す」を担う。
///
/// `withRunner` はゲームロジック（`Dialog` を `do` する側）から見ると Dialog を
/// 提供する handler。プレゼンター（`DialogueView`）と CommandRegistry は
/// 上流で別途 handler を積んでおく必要がある。
mod Dialogue.Runner {
    use Yarn.Types.YarnProject
    use Yarn.VM.{StepResult}
    use Yarn.VM.StepResult.{Running, WaitingLine, WaitingOptions, WaitingCommand,
                             NodeComplete, DialogueComplete, Failed}
    use Dialogue.{PresentedLine, PresentedOption}

    /// 1 命令分の暴走防止に十分な大きい数。
    /// `runUntilWaiting` が同じ pump で 1000 命令以上回ったらバグとみなして打ち切る。
    def maxStepsPerPump(): Int32 = 1000

    /// `Session` effect を実装する handler。
    /// 呼び出し元は `region rc { withRunner(rc, compiledProject, () -> ...) ... }` で使う。
    /// body の中で `do Session.start("Start")` などが呼べるようになる。
    pub def withRunner(rc: Region[r], compiledProject: YarnProject, body: Unit -> a \ ef):
                        a \ (ef - Dialogue.Session) + Dialogue.DialogueView
                          + Dialogue.CommandRegistry + r =
        let vmRef: Ref[Option[Yarn.VM.VM[r]], r] = Ref.fresh(rc, None);
        run body() with handler Dialogue.Session {

            def start(nodeName, resume) = {
                let vm = Yarn.VM.init(rc, compiledProject, nodeName);
                Ref.put(Some(vm), vmRef);
                runUntilWaiting(vm, compiledProject, maxStepsPerPump());
                resume()
            }

            def stop(resume) = {
                Ref.put(None, vmRef);
                Dialogue.DialogueView.dialogueComplete();
                resume()
            }

            def isActive(resume) =
                resume(Option.nonEmpty(Ref.get(vmRef)))

            def submitAdvance(resume) =
                match Ref.get(vmRef) {
                    case Some(vm) => {
                        Yarn.VM.advance(vm);
                        runUntilWaiting(vm, compiledProject, maxStepsPerPump());
                        resume()
                    }
                    case None => resume()
                }

            def submitSelect(optionIndex, resume) =
                match Ref.get(vmRef) {
                    case Some(vm) => {
                        Yarn.VM.selectOption(optionIndex, vm);
                        runUntilWaiting(vm, compiledProject, maxStepsPerPump());
                        resume()
                    }
                    case None => resume()
                }

            def submitCommandDone(resume) =
                match Ref.get(vmRef) {
                    case Some(vm) => {
                        Yarn.VM.commandComplete(vm);
                        runUntilWaiting(vm, compiledProject, maxStepsPerPump());
                        resume()
                    }
                    case None => resume()
                }
        }

    /// VM を 1 つの Waiting* / DialogueComplete に到達するまで step し続ける。
    /// 行・選択肢・コマンドそれぞれに対応する DialogueView 操作を呼ぶ。
    /// VM の暴走を防ぐため最大ステップ数で打ち切る。
    def runUntilWaiting(vm: Yarn.VM.VM[r], compiledProject: YarnProject, remaining: Int32):
                         Unit \ Dialogue.DialogueView + Dialogue.CommandRegistry + r =
        if (remaining <= 0)
            Dialogue.DialogueView.dialogueComplete()
        else
            match Yarn.VM.step(vm) {
                case Running          => runUntilWaiting(vm, compiledProject, remaining - 1)
                case NodeComplete     => runUntilWaiting(vm, compiledProject, remaining - 1)
                case WaitingLine(lineId, substitutions) =>
                    let line = resolveLine(lineId, substitutions, compiledProject);
                    Dialogue.DialogueView.presentLine(line)
                case WaitingOptions(entries) =>
                    let presented = entriesToPresented(entries, compiledProject);
                    Dialogue.DialogueView.presentOptions(presented)
                case WaitingCommand(commandText) => {
                    Dialogue.DialogueView.runCommand(commandText);
                    let synchronous = Dialogue.CommandRegistry.dispatch(commandText);
                    if (synchronous) {
                        Yarn.VM.commandComplete(vm);
                        runUntilWaiting(vm, compiledProject, remaining - 1)
                    } else ()
                }
                case DialogueComplete =>
                    Dialogue.DialogueView.dialogueComplete()
                case Failed(_message) =>
                    // メッセージのロギング層は次フェーズで足す。
                    Dialogue.DialogueView.dialogueComplete()
            }

    /// `Yarn.VM` の OptionEntry から view 用の PresentedOption に整形する。
    /// 表示テキストは StringTable で行 ID を引いて置換解決する。
    def entriesToPresented(entries: List[Yarn.Types.OptionEntry], compiledProject: YarnProject):
                            List[PresentedOption] =
        let toPresented = pair -> {
            let (index, entry) = pair;
            let text = match Yarn.StringTable.resolve(
                            entry#lineId, entry#substitutions, compiledProject#strings) {
                case Ok(resolved) => resolved
                case Err(_)       => entry#lineId
            };
            ({ index = index, text = text, available = entry#available }: PresentedOption)
        };
        let indexed = List.zip(List.range(0, List.length(entries)), entries);
        List.map(toPresented, indexed)

    /// 行 ID と置換から view 用の PresentedLine に整形する。
    /// 話者は `Dialogue.extractSpeaker`（半角コロン区切り）で抽出する。
    /// 別の表記法を採るシナリオでは、Runner を別実装にするか手前で正規化すること。
    def resolveLine(lineId: String, substitutions: List[String], compiledProject: YarnProject):
                     PresentedLine =
        let text = match Yarn.StringTable.resolve(lineId, substitutions, compiledProject#strings) {
            case Ok(resolved) => resolved
            case Err(_)       => lineId
        };
        { lineId = lineId, text = text, speaker = Dialogue.extractSpeaker(text) }
}
