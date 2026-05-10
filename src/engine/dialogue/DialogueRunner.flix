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
    use Yarn.Types.Value
    use Yarn.Types.Value.{BoolV}
    use Yarn.VM.{StepResult}
    use Yarn.VM.StepResult.{Running, WaitingLine, WaitingChoice, WaitingCommand,
                             NodeComplete, DialogueComplete, Failed}
    use Dialogue.{PresentedLine, PresentedChoice}

    /// 1 命令分の暴走防止に十分な大きい数。
    /// `runUntilWaiting` が同じ submit で 1000 命令以上回ったらバグとみなして打ち切る。
    def maxStepsPerSubmit(): Int32 = 1000

    /// `Session` effect を実装する handler。
    /// 呼び出し元は `region rc { withRunner(rc, compiledProject, () -> ...) ... }` で使う。
    /// body の中で `do Session.start("Start")` などが呼べるようになる。
    pub def withRunner(rc: Region[r], compiledProject: YarnProject, body: Unit -> a \ ef):
                        a \ (ef - Dialogue.Session - Yarn.VariableAccess)
                          + Dialogue.DialogueView + Dialogue.CommandRegistry
                          + Yarn.BuiltinExtension.Access + r =
        let vmRef: Ref[Option[Yarn.VM.VM[r]], r] = Ref.fresh(rc, None);
        run body() with handler Yarn.VariableAccess {

            def setBool(name, value, resume) = {
                match Ref.get(vmRef) {
                    case Some(vm) => Yarn.VariableStorage.set(name, BoolV(value), vm#variables)
                    case None     => ()
                };
                resume()
            }

            def getBool(name, resume) = {
                let result = match Ref.get(vmRef) {
                    case Some(vm) =>
                        match Yarn.VariableStorage.get(name, vm#variables) {
                            case Some(BoolV(b)) => Some(b)
                            case _              => None
                        }
                    case None => None
                };
                resume(result)
            }

            def currentNode(resume) =
                resume(match Ref.get(vmRef) {
                    case Some(vm) => Ref.get(vm#currentNode)
                    case None     => None
                })

            def variableSnapshot(resume) =
                resume(match Ref.get(vmRef) {
                    case Some(vm) => Yarn.VariableStorage.toMap(vm#variables)
                    case None     => Map.empty()
                })
        } with handler Dialogue.Session {

            def start(nodeName, resume) = {
                let vm = Yarn.VM.init(rc, compiledProject, nodeName);
                Ref.put(Some(vm), vmRef);
                runUntilWaiting(vm, compiledProject, maxStepsPerSubmit());
                resume()
            }

            def stop(resume) = {
                Ref.put(None, vmRef);
                Dialogue.DialogueView.dialogueComplete();
                resume()
            }

            def isActive(resume) =
                // VM が起動済みかつ currentNode を持つ (= まだ DialogueComplete に
                // 到達していない) ときだけ active 扱いにする。VM が return/stop で
                // currentNode を None にした後は idle として扱い、探索モードの
                // クリック判定など外側の入力処理を許可する。
                resume(match Ref.get(vmRef) {
                    case None     => false
                    case Some(vm) => Option.nonEmpty(Ref.get(vm#currentNode))
                })

            def submitNext(resume) =
                match Ref.get(vmRef) {
                    case Some(vm) => {
                        Yarn.VM.next(vm);
                        runUntilWaiting(vm, compiledProject, maxStepsPerSubmit());
                        resume()
                    }
                    case None => resume()
                }

            def submitSelect(choiceIndex, resume) =
                match Ref.get(vmRef) {
                    case Some(vm) => {
                        Yarn.VM.selectChoice(choiceIndex, vm);
                        runUntilWaiting(vm, compiledProject, maxStepsPerSubmit());
                        resume()
                    }
                    case None => resume()
                }

            def submitCommandDone(resume) =
                match Ref.get(vmRef) {
                    case Some(vm) => {
                        Yarn.VM.commandComplete(vm);
                        runUntilWaiting(vm, compiledProject, maxStepsPerSubmit());
                        resume()
                    }
                    case None => resume()
                }

            def restart(nodeName, variables, resume) = {
                // 新 VM を作って variables を流し込んでから走らせる。
                // start() より前に変数を入れるのが肝。ノード冒頭で `{$brave}` 等を
                // 参照するセリフが復元値で正しく substitute される。
                let vm = Yarn.VM.init(rc, compiledProject, nodeName);
                Map.forEach((name, value) ->
                    Yarn.VariableStorage.set(name, value, vm#variables),
                    variables);
                Ref.put(Some(vm), vmRef);
                runUntilWaiting(vm, compiledProject, maxStepsPerSubmit());
                resume()
            }
        }

    /// VM を 1 つの Waiting* / DialogueComplete に到達するまで step し続ける。
    /// 行・選択肢・コマンドそれぞれに対応する DialogueView 操作を呼ぶ。
    /// VM の暴走を防ぐため最大ステップ数で打ち切る。
    def runUntilWaiting(vm: Yarn.VM.VM[r], compiledProject: YarnProject, remaining: Int32):
                         Unit \ Dialogue.DialogueView + Dialogue.CommandRegistry
                              + Yarn.BuiltinExtension.Access + r =
        if (remaining <= 0)
            Dialogue.DialogueView.dialogueComplete()
        else
            match Yarn.VM.step(vm) {
                case Running          => runUntilWaiting(vm, compiledProject, remaining - 1)
                case NodeComplete     => runUntilWaiting(vm, compiledProject, remaining - 1)
                case WaitingLine(lineId, substitutions) =>
                    let line = resolveLine(lineId, substitutions, compiledProject);
                    Dialogue.DialogueView.presentLine(line)
                case WaitingChoice(entries) =>
                    let choices = entriesToChoices(entries, compiledProject);
                    Dialogue.DialogueView.presentChoices(choices)
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

    /// `Yarn.VM` の ChoiceEntry から view 用の PresentedChoice に整形する。
    /// 表示テキストは StringTable で行 ID を引いて置換解決する。
    def entriesToChoices(entries: List[Yarn.Types.ChoiceEntry], compiledProject: YarnProject):
                            List[PresentedChoice] =
        let toChoice = pair -> {
            let (index, entry) = pair;
            let text = match Yarn.StringTable.resolve(
                            entry#lineId, entry#substitutions, compiledProject#strings) {
                case Ok(resolved) => resolved
                case Err(_)       => entry#lineId
            };
            ({ index = index, text = text, available = entry#available }: PresentedChoice)
        };
        let indexed = List.zip(List.range(0, List.length(entries)), entries);
        List.map(toChoice, indexed)

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
