/// `yarn/output.json` のフルシナリオ動作確認。
///
/// ローダ + VM + ビルトイン関数を統合したエンドツーエンドテスト。
/// 「はい」を選んだ場合と「いいえ」を選んだ場合の両方で、
/// 期待されるイベントの並びが正しく出ることを保証する。
///
/// 「いいえ」を選ぶと Start に再帰してしまうので、最大ステップ数で
/// 必ず打ち切る。最大ステップガードが効くこと自体をテストする。
mod TestYarnScenario {
    use Yarn.Types.{YarnProject, LineRef}
    use Yarn.VM.{VM, StepResult}
    use Yarn.VM.StepResult.{Running, WaitingLine, WaitingChoice, WaitingCommand,
                             NodeComplete, DialogueComplete, Failed}

    /// 表面化するイベント（VM 内部の Running / NodeComplete は含まない）。
    /// テスト期待値の比較に使う。
    pub enum ScenarioEvent with Eq, ToString {
        case Line(LineRef, List[String])
        case Options(List[LineRef])
        case Command(String)
        case Done
        case StoppedAtLimit
    }

    /// プレイヤーの選択。`Yes` は 0 番目、`No` は 1 番目を選ぶ簡易ラベル。
    pub enum Choice with Eq, ToString {
        case Yes
        case No
    }

    // fixture は `TestYarnFixture.loadProject()` 経由でインライン取得する。

    /// VM を駆動して、各 Waiting* / Done に到達した時点でイベントを記録する。
    /// 選択肢に当たったら choices の先頭を消費して selectChoice する。
    /// maxSteps を超えたら StoppedAtLimit を末尾に付けて打ち切る。
    def runScenario(vm: VM[r], choices: List[Choice], maxSteps: Int32):
                     List[ScenarioEvent] \ r + Yarn.BuiltinExtension.Access =
        loop(vm, choices, maxSteps, Nil) |> List.reverse

    def loop(vm: VM[r], choices: List[Choice], remaining: Int32,
              acc: List[ScenarioEvent]): List[ScenarioEvent] \ r + Yarn.BuiltinExtension.Access =
        if (remaining <= 0)
            ScenarioEvent.StoppedAtLimit :: acc
        else
            match Yarn.VM.step(vm) {
                case Running        => loop(vm, choices, remaining - 1, acc)
                case NodeComplete   => loop(vm, choices, remaining - 1, acc)
                case WaitingLine(lineRef, substitutions) =>
                    Yarn.VM.next(vm);
                    loop(vm, choices, remaining - 1,
                         ScenarioEvent.Line(lineRef, substitutions) :: acc)
                case WaitingChoice(entries) =>
                    let lineIds = List.map(entry -> entry#lineId, entries);
                    let (selectedIndex, restChoices) = nextChoiceIndex(choices);
                    Yarn.VM.selectChoice(selectedIndex, vm);
                    loop(vm, restChoices, remaining - 1,
                         ScenarioEvent.Options(lineIds) :: acc)
                case WaitingCommand(text) =>
                    Yarn.VM.commandComplete(vm);
                    loop(vm, choices, remaining - 1,
                         ScenarioEvent.Command(text) :: acc)
                case DialogueComplete =>
                    ScenarioEvent.Done :: acc
                case Failed(message) =>
                    bug!("VM error during scenario: ${message}")
            }

    /// choices の先頭を消費して index と残りを返す。空なら 0 を返す（保険）。
    def nextChoiceIndex(choices: List[Choice]): (Int32, List[Choice]) =
        match choices {
            case Choice.Yes :: rest => (0, rest)
            case Choice.No :: rest  => (1, rest)
            case Nil                => (0, Nil)
        }

    // ========================================================================
    // 「はい」を選んだときの完全なイベント列
    //
    // 期待される並び:
    //   1. line:9110649c   (おう: ゆうしゃよ…)
    //   2. line:072063eb   (おう: まおうを…)
    //   3. options [はい, いいえ]   ← 選択は はい
    //   4. line:2b416d05   (たのもしいぞ)
    //   5. line:7fc00f8b ["0"]   (HPは 0 ある — $hp 置換)
    //   6. command "wait 0.5"
    //   7. line:e9f008fc   (たびだちじゃ)
    //   8. Done
    // ========================================================================

    /// 「はい」を 1 回選ぶと、Quest ノードを通って対話が完了する。
    @Test
    def testYesChoiceScenario(): Unit \ Assert =
        let loaded = TestYarnFixture.loadProject();
        let events = region rc {
            run {
                let vm = Yarn.VM.init(rc, loaded, "Start");
                runScenario(vm, Choice.Yes :: Nil, 1000)
            } with Yarn.BuiltinExtension.withNoExtension
        };
        let expected: List[ScenarioEvent] =
            ScenarioEvent.Line("line:9110649c", Nil) ::
            ScenarioEvent.Line("line:072063eb", Nil) ::
            ScenarioEvent.Options("line:bd716a72" :: "line:88d4099b" :: Nil) ::
            ScenarioEvent.Line("line:2b416d05", Nil) ::
            ScenarioEvent.Line("line:7fc00f8b", "0" :: Nil) ::
            ScenarioEvent.Command("wait 0.5") ::
            ScenarioEvent.Line("line:e9f008fc", Nil) ::
            ScenarioEvent.Done :: Nil;
        Assert.assertEq(expected = expected, events)

    // ========================================================================
    // 「いいえ」を選んだときの再帰
    //
    // 「いいえ」→ ip=20 → pop → runLine line:1ee40eec → runNode Start で再帰。
    // 連続で「いいえ」を選び続けると無限ループするので、max ステップで打ち切る。
    // ========================================================================

    /// 「いいえ」を 1 回選んだあと、再帰で Start に戻り、最初の line:9110649c が再表示される。
    /// その後も「いいえ」を選び続けるが、まずは「いいえ」1 回時点での前 4 イベントを確認する。
    @Test
    def testNoChoiceTriggersRecursion(): Unit \ Assert =
        let loaded = TestYarnFixture.loadProject();
        // 「いいえ」を 100 回（実質無限）。max ステップで切られる前提。
        let manyNoChoices = List.repeat(100, Choice.No);
        let events = region rc {
            run {
                let vm = Yarn.VM.init(rc, loaded, "Start");
                runScenario(vm, manyNoChoices, 1000)
            } with Yarn.BuiltinExtension.withNoExtension
        };
        // 最後のイベントが StoppedAtLimit であること（無限再帰がガードされた）と、
        // 先頭 5 イベントが期待どおりであることを 1 度に確認する。
        let firstFive = List.take(5, events);
        let last = List.last(events);
        let expectedFirstFive: List[ScenarioEvent] =
            ScenarioEvent.Line("line:9110649c", Nil) ::
            ScenarioEvent.Line("line:072063eb", Nil) ::
            ScenarioEvent.Options("line:bd716a72" :: "line:88d4099b" :: Nil) ::
            ScenarioEvent.Line("line:1ee40eec", Nil) ::    // なさけないやつめ
            ScenarioEvent.Line("line:9110649c", Nil) ::    // Start 再帰でまた最初から
            Nil;
        Assert.assertEq(
            expected = (expectedFirstFive, Some(ScenarioEvent.StoppedAtLimit)),
            (firstFive, last))

    /// 最大ステップ数を 5 に絞ると、最初の Line に到達した直後で打ち切られる。
    /// `runScenario` の打ち切り保護が機能していることを確認する。
    @Test
    def testStepLimitGuardsAgainstInfiniteLoop(): Unit \ Assert =
        let loaded = TestYarnFixture.loadProject();
        let events = region rc {
            run {
                let vm = Yarn.VM.init(rc, loaded, "Start");
                runScenario(vm, Choice.No :: Nil, 5)
            } with Yarn.BuiltinExtension.withNoExtension
        };
        // 5 ステップ以内で Line(9110649c) が出て、その後すぐ StoppedAtLimit。
        Assert.assertEq(expected = Some(ScenarioEvent.StoppedAtLimit), List.last(events))
}
