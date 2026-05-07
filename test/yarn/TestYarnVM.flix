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
            let vm = Yarn.VM.init(rc, loaded, "Main");
            // pushString, pushFloat, callFunc, jumpIfFalse, return の 5 命令を進める。
            // ジャンプが効いていれば pop は飛ばされて、ip=5 の return に直接到達する。
            discard Yarn.VM.step(vm); // pushString
            discard Yarn.VM.step(vm); // pushFloat
            discard Yarn.VM.step(vm); // callFunc
            discard Yarn.VM.step(vm); // jumpIfFalse → ip=5
            stepResultLabel(Yarn.VM.step(vm))
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
            let vm = Yarn.VM.init(rc, loaded, "Main");
            discard Yarn.VM.step(vm);
            discard Yarn.VM.step(vm);
            discard Yarn.VM.step(vm);
            discard Yarn.VM.step(vm);
            match Yarn.VM.step(vm) {
                case WaitingLine(lineId, _) => lineId
                case _                       => bug!("expected WaitingLine after fall-through")
            }
        };
        Assert.assertEq(expected = "line:reached", lineRef)

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
            let vm = Yarn.VM.init(rc, loaded, "Main");
            // step #1: runNode Sub を実行し、Sub の visiting カウンタを +1 にする。
            discard Yarn.VM.step(vm);
            // 訪問カウンタを直接読む。
            let countMain = Yarn.Builtins.call(
                "visited_count", StringV("Main") :: Nil, vm#variables);
            let countSub = Yarn.Builtins.call(
                "visited_count", StringV("Sub") :: Nil, vm#variables);
            (countMain, countSub)
        };
        let expectedMain: Result[String, Value] = Ok(FloatV(1.0));
        let expectedSub: Result[String, Value]  = Ok(FloatV(1.0));
        Assert.assertEq(expected = (expectedMain, expectedSub), counts)
}
