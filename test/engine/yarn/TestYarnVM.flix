/// VM の振る舞いを opcode 単位で確認するテスト。
///
/// 自明な「push したものが pop で出てくる」式のテストは `TestYarnScenario` の
/// 全体実行に任せ、ここでは「自明でない遷移」だけを書く。
///
/// VM の構築は実物の `Yarn.Loader.parseProject` を経由する。手で VM 状態を
/// 組み立てると公開 API を回避してしまい、リファクタに弱くなるため。
///
/// `StepResult` は `Eq` を派生していないため、`match` で取り出した値を
/// プリミティブにしてから `assertEq` で比較する。
///
/// `Yarn.VM.step` は `Yarn.BuiltinExtension.Access` を要求するため、各テストは
/// `withNoExtension` で 1 段ハンドラを被せる（拡張なしで engine 同梱 builtin だけを
/// 評価する）。
mod TestYarnVM {
    use Yarn.Types.{YarnProject, Value}
    use Yarn.Types.Value.{BoolV, FloatV, StringV}
    use Yarn.VM.{StepResult}
    use Yarn.VM.StepResult.{Running, WaitingLine, NodeComplete, DialogueComplete, Failed}

    /// 1 ノードだけの極小プログラムを parse して返すヘルパー。
    /// instructions は JSON 配列の文字列を直接渡す（`{"pop":{}}` 等）。
    /// initialValues は省略（空オブジェクト）。
    def buildProject(nodeName: String, instructionsJson: String): YarnProject =
        let projectJson =
            "{\"program\":{\"name\":\"\","
              + "\"nodes\":{\"" + nodeName + "\":{\"name\":\"" + nodeName + "\","
              + "\"headers\":[],\"instructions\":" + instructionsJson + "}},"
              + "\"initialValues\":{},\"languageVersion\":4},"
              + "\"strings\":{}}";
        match Yarn.Loader.parseProject(projectJson) {
            case Ok(loaded)  => loaded
            case Err(_)      => bug!("synthetic project failed to parse")
        }

    /// `StepResult` を「DialogueComplete か」「WaitingLine の lineId と subs 何か」など
    /// アサート可能なタプルへ整形する小さなヘルパー。
    def stepResultLabel(result: StepResult): String = match result {
        case Running                  => "Running"
        case WaitingLine(_, _)        => "WaitingLine"
        case NodeComplete             => "NodeComplete"
        case DialogueComplete         => "DialogueComplete"
        case Failed(_)                => "Failed"
        case _                        => "Other"
    }

    // ========================================================================
    // JumpIfFalse: stack top の真偽でジャンプ先が決まる
    // ========================================================================

    /// stack top が `false` のとき jumpIfFalse は destination に飛ぶ。
    /// 命令列:
    ///   0. pushString "Start"  (まだ訪問されていないノード名)
    ///   1. pushFloat 1
    ///   2. callFunc visited    → stack top = BoolV(false)（"Start" は未訪問）
    ///   3. jumpIfFalse 5       → false なので ip = 5 へ飛ぶ
    ///   4. pop                 (来ない)
    ///   5. return              (ジャンプ先 → DialogueComplete)
    @Test
    def testJumpIfFalseTakesBranchOnFalse(): Unit \ Assert =
        let instructions =
            "[" +
            "{\"pushString\":{\"value\":\"NotYetVisited\"}}," +
            "{\"pushFloat\":{\"value\":1}}," +
            "{\"callFunc\":{\"functionName\":\"visited\"}}," +
            "{\"jumpIfFalse\":{\"destination\":5}}," +
            "{\"pop\":{}}," +
            "{\"return\":{}}" +
            "]";
        let loaded = buildProject("Main", instructions);
        let label = region rc {
            run {
                let vm = Yarn.VM.init(rc, loaded, "Main");
                discard Yarn.VM.step(vm); // pushString
                discard Yarn.VM.step(vm); // pushFloat
                discard Yarn.VM.step(vm); // callFunc
                discard Yarn.VM.step(vm); // jumpIfFalse → ip=5
                stepResultLabel(Yarn.VM.step(vm))
            } with Yarn.BuiltinExtension.withNoExtension
        };
        Assert.assertEq(expected = "DialogueComplete", label)

    /// stack top が `true` のとき jumpIfFalse は次の命令に進む（fall-through）。
    /// VM.init は開始ノード Main の visiting カウンタを 1 にしているので、
    /// `visited("Main")` は true。
    /// 命令列:
    ///   0. pushString "Main"
    ///   1. pushFloat 1
    ///   2. callFunc visited       → stack top = BoolV(true)
    ///   3. jumpIfFalse 5          → true なので fall-through、ip=4
    ///   4. runLine "line:reached" → WaitingLine
    ///   5. return
    @Test
    def testJumpIfFalseFallsThroughOnTrue(): Unit \ Assert =
        let instructions =
            "[" +
            "{\"pushString\":{\"value\":\"Main\"}}," +
            "{\"pushFloat\":{\"value\":1}}," +
            "{\"callFunc\":{\"functionName\":\"visited\"}}," +
            "{\"jumpIfFalse\":{\"destination\":5}}," +
            "{\"runLine\":{\"lineID\":\"line:reached\",\"substitutionCount\":0}}," +
            "{\"return\":{}}" +
            "]";
        let loaded = buildProject("Main", instructions);
        let lineRef = region rc {
            run {
                let vm = Yarn.VM.init(rc, loaded, "Main");
                discard Yarn.VM.step(vm);
                discard Yarn.VM.step(vm);
                discard Yarn.VM.step(vm);
                discard Yarn.VM.step(vm);
                match Yarn.VM.step(vm) {
                    case WaitingLine(lineId, _) => lineId
                    case _                       => bug!("expected WaitingLine after fall-through")
                }
            } with Yarn.BuiltinExtension.withNoExtension
        };
        Assert.assertEq(expected = "line:reached", lineRef)

    // ========================================================================
    // PushBool: 真偽リテラルがスタック・変数に伝播する
    // ========================================================================

    /// `<<set $brave = true>>` 由来の `pushBool true; storeVariable $brave; pop`
    /// が走ると、`$brave` が BoolV(true) として読めるようになる。
    /// 命令列:
    ///   0. pushBool true
    ///   1. storeVariable "$brave"
    ///   2. pop
    ///   3. return
    @Test
    def testPushBoolStoresTrueIntoVariable(): Unit \ Assert =
        let instructions =
            "[" +
            "{\"pushBool\":{\"value\":true}}," +
            "{\"storeVariable\":{\"variableName\":\"\$brave\"}}," +
            "{\"pop\":{}}," +
            "{\"return\":{}}" +
            "]";
        let loaded = buildProject("Main", instructions);
        let stored = region rc {
            run {
                let vm = Yarn.VM.init(rc, loaded, "Main");
                discard Yarn.VM.step(vm); // pushBool
                discard Yarn.VM.step(vm); // storeVariable
                discard Yarn.VM.step(vm); // pop
                Yarn.VariableStorage.get("\$brave", vm#variables)
            } with Yarn.BuiltinExtension.withNoExtension
        };
        Assert.assertEq(expected = Some(BoolV(true)), stored)

    /// `pushBool false` のあと `jumpIfFalse` が分岐に乗る — 真偽値の peek が
    /// `pushFloat` ではなく `pushBool` 経由でも正しく機能することの確認。
    /// 命令列:
    ///   0. pushBool false
    ///   1. jumpIfFalse 3
    ///   2. runLine "line:skipped"  (来ない)
    ///   3. return
    @Test
    def testPushBoolFalseTriggersJumpIfFalse(): Unit \ Assert =
        let instructions =
            "[" +
            "{\"pushBool\":{\"value\":false}}," +
            "{\"jumpIfFalse\":{\"destination\":3}}," +
            "{\"runLine\":{\"lineID\":\"line:skipped\",\"substitutionCount\":0}}," +
            "{\"return\":{}}" +
            "]";
        let loaded = buildProject("Main", instructions);
        let label = region rc {
            run {
                let vm = Yarn.VM.init(rc, loaded, "Main");
                discard Yarn.VM.step(vm); // pushBool false
                discard Yarn.VM.step(vm); // jumpIfFalse → ip=3
                stepResultLabel(Yarn.VM.step(vm))
            } with Yarn.BuiltinExtension.withNoExtension
        };
        Assert.assertEq(expected = "DialogueComplete", label)

    // ========================================================================
    // RunNode: callStack に戻り先を積み、訪問カウンタを 1 上げる
    // ========================================================================

    /// runNode "Sub" を実行すると、Sub の visiting カウンタが 1 になる。
    /// VM.init は開始ノード Main の visiting を 1 にしている。
    /// 命令列（Main）:
    ///   0. runNode "Sub"
    ///   1. return
    /// 命令列（Sub）:
    ///   0. return
    @Test
    def testRunNodeIncrementsVisitingCounter(): Unit \ Assert =
        let projectJson =
            "{\"program\":{\"name\":\"\",\"nodes\":{" +
            "\"Main\":{\"name\":\"Main\",\"headers\":[],\"instructions\":[" +
              "{\"runNode\":{\"nodeName\":\"Sub\"}}," +
              "{\"return\":{}}" +
            "]}," +
            "\"Sub\":{\"name\":\"Sub\",\"headers\":[],\"instructions\":[" +
              "{\"return\":{}}" +
            "]}}," +
            "\"initialValues\":{},\"languageVersion\":4},\"strings\":{}}";
        let loaded = match Yarn.Loader.parseProject(projectJson) {
            case Ok(p)  => p
            case Err(_) => bug!("synthetic Main+Sub project failed")
        };
        let counts = region rc {
            run {
                let vm = Yarn.VM.init(rc, loaded, "Main");
                // step #1: runNode Sub を実行し、Sub の visiting カウンタを +1 にする。
                discard Yarn.VM.step(vm);
                // 訪問カウンタを直接読む。
                let countMain = Yarn.Builtins.call(
                    "visited_count", StringV("Main") :: Nil, vm#variables);
                let countSub = Yarn.Builtins.call(
                    "visited_count", StringV("Sub") :: Nil, vm#variables);
                (countMain, countSub)
            } with Yarn.BuiltinExtension.withNoExtension
        };
        let expectedMain: Result[String, Value] = Ok(FloatV(1.0));
        let expectedSub: Result[String, Value]  = Ok(FloatV(1.0));
        Assert.assertEq(expected = (expectedMain, expectedSub), counts)

    // ========================================================================
    // RunNode は jump-style: 戻り先を積まない
    // ========================================================================

    /// `<<jump Sub>>` 由来の runNode は callStack を積まない。Sub の return で
    /// dialogue 全体が完了する（Main へは戻らない）。
    /// 命令列（Main）:
    ///   0. runNode "Sub"
    ///   1. runLine "line:should-not-run"   (戻ってきたら誤検出される行)
    ///   2. return
    /// 命令列（Sub）:
    ///   0. return
    @Test
    def testRunNodeDoesNotPushFrame(): Unit \ Assert =
        let projectJson =
            "{\"program\":{\"name\":\"\",\"nodes\":{" +
            "\"Main\":{\"name\":\"Main\",\"headers\":[],\"instructions\":[" +
              "{\"runNode\":{\"nodeName\":\"Sub\"}}," +
              "{\"runLine\":{\"lineID\":\"line:should-not-run\",\"substitutionCount\":0}}," +
              "{\"return\":{}}" +
            "]}," +
            "\"Sub\":{\"name\":\"Sub\",\"headers\":[],\"instructions\":[" +
              "{\"return\":{}}" +
            "]}}," +
            "\"initialValues\":{},\"languageVersion\":4},\"strings\":{}}";
        let loaded = match Yarn.Loader.parseProject(projectJson) {
            case Ok(p)  => p
            case Err(_) => bug!("synthetic project failed")
        };
        let label = region rc {
            run {
                let vm = Yarn.VM.init(rc, loaded, "Main");
                discard Yarn.VM.step(vm); // runNode Sub
                stepResultLabel(Yarn.VM.step(vm)) // Sub の return
            } with Yarn.BuiltinExtension.withNoExtension
        };
        Assert.assertEq(expected = "DialogueComplete", label)

    // ========================================================================
    // Detour は subroutine-style: 戻り先を積み、return で復帰
    // ========================================================================

    /// `<<detour Sub>>` 由来の Detour は callStack に Main を積み、Sub の return で
    /// Main の続きが実行される。
    /// 命令列（Main）:
    ///   0. detourToNode "Sub"
    ///   1. runLine "line:after-detour"   (Sub から戻ってきて到達する行)
    ///   2. return
    /// 命令列（Sub）:
    ///   0. return
    @Test
    def testDetourReturnsToCaller(): Unit \ Assert =
        let projectJson =
            "{\"program\":{\"name\":\"\",\"nodes\":{" +
            "\"Main\":{\"name\":\"Main\",\"headers\":[],\"instructions\":[" +
              "{\"detourToNode\":{\"nodeName\":\"Sub\"}}," +
              "{\"runLine\":{\"lineID\":\"line:after-detour\",\"substitutionCount\":0}}," +
              "{\"return\":{}}" +
            "]}," +
            "\"Sub\":{\"name\":\"Sub\",\"headers\":[],\"instructions\":[" +
              "{\"return\":{}}" +
            "]}}," +
            "\"initialValues\":{},\"languageVersion\":4},\"strings\":{}}";
        let loaded = match Yarn.Loader.parseProject(projectJson) {
            case Ok(p)  => p
            case Err(_) => bug!("synthetic project failed")
        };
        let lineRef = region rc {
            run {
                let vm = Yarn.VM.init(rc, loaded, "Main");
                discard Yarn.VM.step(vm); // detourToNode Sub
                discard Yarn.VM.step(vm); // Sub の return → NodeComplete、Main ip=1 へ
                match Yarn.VM.step(vm) {  // runLine "line:after-detour"
                    case WaitingLine(id, _) => id
                    case _                  => bug!("expected WaitingLine after detour return")
                }
            } with Yarn.BuiltinExtension.withNoExtension
        };
        Assert.assertEq(expected = "line:after-detour", lineRef)

    // ========================================================================
    // Stop: callStack 残留があっても即 DialogueComplete
    // ========================================================================

    /// `<<stop>>` は callStack を破棄して dialogue を即終了する。
    /// detour 経由で Sub に居る最中に Stop しても、Main へ戻らずに DialogueComplete。
    /// 命令列（Main）:
    ///   0. detourToNode "Sub"
    ///   1. runLine "line:never"   (Stop なら絶対到達しない行)
    ///   2. return
    /// 命令列（Sub）:
    ///   0. stop
    @Test
    def testStopClearsCallStackAndCompletes(): Unit \ Assert =
        let projectJson =
            "{\"program\":{\"name\":\"\",\"nodes\":{" +
            "\"Main\":{\"name\":\"Main\",\"headers\":[],\"instructions\":[" +
              "{\"detourToNode\":{\"nodeName\":\"Sub\"}}," +
              "{\"runLine\":{\"lineID\":\"line:never\",\"substitutionCount\":0}}," +
              "{\"return\":{}}" +
            "]}," +
            "\"Sub\":{\"name\":\"Sub\",\"headers\":[],\"instructions\":[" +
              "{\"stop\":{}}" +
            "]}}," +
            "\"initialValues\":{},\"languageVersion\":4},\"strings\":{}}";
        let loaded = match Yarn.Loader.parseProject(projectJson) {
            case Ok(p)  => p
            case Err(_) => bug!("synthetic project failed")
        };
        let label = region rc {
            run {
                let vm = Yarn.VM.init(rc, loaded, "Main");
                discard Yarn.VM.step(vm); // detourToNode Sub
                stepResultLabel(Yarn.VM.step(vm)) // Sub の stop → DialogueComplete
            } with Yarn.BuiltinExtension.withNoExtension
        };
        Assert.assertEq(expected = "DialogueComplete", label)
}
