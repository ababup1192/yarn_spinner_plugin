/// `yarn/story.yarn` の各分岐フローを VM レベルで駆動するシナリオテスト。
///
/// 目的:
///   - 「にげる成功で Ending ではなく Room1 に戻る」のような分岐挙動の回帰テスト
///   - こうげき(brave/not brave) / にげる(成功/失敗) / やすむ / たからばこ /
///     とびら / Intro 名前選択 / Ending / GameOver の各選択肢が
///     期待どおりのコマンド列・変数遷移になることを保証
///
/// 戦略:
///   - `TestStoryFixture.loadProject()` で実物の story.yarn コンパイル結果をロード
///   - 任意のノードから VM を起動し、選択肢に来たら入力済み index を消費
///   - 走った WaitingCommand / WaitingLine / WaitingOptions を `ScenarioEvent`
///     列として記録し、含有・並び・先頭 N 件でアサート
///   - 変数の遷移確認は `region rc { ... }` 内で `vm#variables` を直接読む
///   - ループや無限再帰に備えて `maxSteps` で打ち切る
mod TestStoryScenario {
    use Yarn.Types.{YarnProject, LineRef, Value}
    use Yarn.Types.Value.{BoolV, FloatV, StringV}
    use Yarn.VM.{VM, StepResult}
    use Yarn.VM.StepResult.{Running, WaitingLine, WaitingOptions, WaitingCommand,
                             NodeComplete, DialogueComplete, Failed}

    /// 表面化するイベント（VM 内部の Running / NodeComplete は含めない）。
    pub enum ScenarioEvent with Eq, ToString {
        case Line(LineRef)
        case Options(Int32)             // 選択肢の数だけ持つ（中身までは見ない簡易版）
        case Command(String)
        case Done
        case StoppedAtLimit
    }

    /// VM を駆動。選択肢に当たったら `choiceIndices` の先頭を index として消費する。
    /// `maxSteps` を超えたら `StoppedAtLimit` を末尾に付けて打ち切る。
    pub def runScenario(vm: VM[r], choiceIndices: List[Int32], maxSteps: Int32):
                         List[ScenarioEvent] \ r =
        loop(vm, choiceIndices, maxSteps, Nil) |> List.reverse

    def loop(vm: VM[r], choiceIndices: List[Int32], remaining: Int32,
              acc: List[ScenarioEvent]): List[ScenarioEvent] \ r =
        if (remaining <= 0)
            ScenarioEvent.StoppedAtLimit :: acc
        else
            match Yarn.VM.step(vm) {
                case Running        => loop(vm, choiceIndices, remaining - 1, acc)
                case NodeComplete   => loop(vm, choiceIndices, remaining - 1, acc)
                case WaitingLine(lineRef, _subs) =>
                    Yarn.VM.next(vm);
                    loop(vm, choiceIndices, remaining - 1,
                         ScenarioEvent.Line(lineRef) :: acc)
                case WaitingOptions(options) =>
                    let count = List.length(options);
                    let (selectedIndex, restChoices) = match choiceIndices {
                        case head :: tail => (head, tail)
                        case Nil          => (0, Nil)
                    };
                    Yarn.VM.selectOption(selectedIndex, vm);
                    loop(vm, restChoices, remaining - 1,
                         ScenarioEvent.Options(count) :: acc)
                case WaitingCommand(text) =>
                    Yarn.VM.commandComplete(vm);
                    loop(vm, choiceIndices, remaining - 1,
                         ScenarioEvent.Command(text) :: acc)
                case DialogueComplete =>
                    ScenarioEvent.Done :: acc
                case Failed(message) =>
                    bug!("VM error during scenario: ${message}")
            }

    /// `events` から Command 文字列だけを順に取り出す。
    def commandsOf(events: List[ScenarioEvent]): List[String] =
        List.filterMap(event -> match event {
            case ScenarioEvent.Command(text) => Some(text)
            case _                            => None
        }, events)

    /// `events` のなかに `cmd` というコマンドが含まれるか。
    def containsCommand(cmd: String, events: List[ScenarioEvent]): Bool =
        List.memberOf(cmd, commandsOf(events))

    // ════════════════════════════════════════════════════════════════════════
    // (A) Battle にげる成功で Room1 に戻る（回帰テスト）
    // ════════════════════════════════════════════════════════════════════════

    /// Battle ノード開始 → BattleLoop に detour → にげる(index 1)を選択。
    /// 初期 HP=100 で BattleLoop が -25 して 75、`$hp > 50` 成立で逃走成功。
    /// 期待: `sprite hide dragon` + Room1 の `bg room1 fade 0.5` が発火し、
    ///       Ending の `bg ending fade 1.0` は **発火しない**。
    @Test
    def testFleeSuccessReturnsToRoom1(): Unit \ {Assert, IO} =
        let loaded = TestStoryFixture.loadProject();
        let events = region rc {
            let vm = Yarn.VM.init(rc, loaded, "Battle");
            // BattleLoop の最初の選択肢で "にげる" (index 1)
            runScenario(vm, 1 :: Nil, 500)
        };
        let bgCommands = List.filter(
            s -> String.startsWith({prefix = "bg "}, s),
            commandsOf(events));
        // bg は "bg boss fade 0.3"（Battle 入口）→ "bg room1 fade 0.5"（Room1 入口）の順。
        // Ending の "bg ending fade 1.0" は出ないこと。
        // 後続: 選択肢の指定が尽きると runner が default 0（たからばこ）を選び続ける
        // ので Room1 → Chest → Room1 のループで bg_room1 が何度も出る。先頭 2 件で判定。
        let firstTwoBg = List.take(2, bgCommands);
        let hasEndingBg = containsCommand("bg ending fade 1.0", events);
        Assert.assertEq(
            expected = ("bg boss fade 0.3" :: "bg room1 fade 0.5" :: Nil, false),
            (firstTwoBg, hasEndingBg))

    /// にげる成功で `sprite hide dragon` が発火することを単体で確認。
    @Test
    def testFleeSuccessHidesDragon(): Unit \ {Assert, IO} =
        let loaded = TestStoryFixture.loadProject();
        let events = region rc {
            let vm = Yarn.VM.init(rc, loaded, "Battle");
            runScenario(vm, 1 :: Nil, 500)
        };
        Assert.assertEq(
            expected = true,
            containsCommand("sprite hide dragon", events))

    // ════════════════════════════════════════════════════════════════════════
    // (B) Battle にげる失敗 (HP <= 50)
    // ════════════════════════════════════════════════════════════════════════

    /// $hp=40 にして Battle 開始。BattleLoop の最初で -25 して 15、
    /// `$hp > 50` 不成立で「にげきれない」→ BattleLoop 再突入 → さらに -25 で -10、
    /// `$hp <= 0` で GameOver に jump する。
    /// 期待: GameOver 入口の `bg gameover fade 0.8` が発火する。
    @Test
    def testFleeFailureLeadsToGameOverWhenHpDrops(): Unit \ {Assert, IO} =
        let loaded = TestStoryFixture.loadProject();
        let events = region rc {
            let vm = Yarn.VM.init(rc, loaded, "Battle");
            Yarn.VariableStorage.set("\$hp", FloatV(40.0), vm#variables);
            runScenario(vm, 1 :: 1 :: Nil, 500)
        };
        Assert.assertEq(
            expected = true,
            containsCommand("bg gameover fade 0.8", events))

    // ════════════════════════════════════════════════════════════════════════
    // (C) Battle こうげき + brave で Ending
    // ════════════════════════════════════════════════════════════════════════

    /// $brave=true で Battle 開始。こうげき(index 0) を選ぶとクリティカル分岐に入り、
    /// `<<return>>` で Battle に戻って `<<jump Ending>>` に進む。
    /// 期待: Ending 入口の `bg ending fade 1.0` が発火する。
    @Test
    def testBraveCriticalLeadsToEnding(): Unit \ {Assert, IO} =
        let loaded = TestStoryFixture.loadProject();
        let events = region rc {
            let vm = Yarn.VM.init(rc, loaded, "Battle");
            Yarn.VariableStorage.set("\$brave", BoolV(true), vm#variables);
            runScenario(vm, 0 :: Nil, 500)
        };
        Assert.assertEq(
            expected = true,
            containsCommand("bg ending fade 1.0", events))

    // ════════════════════════════════════════════════════════════════════════
    // (D) Battle こうげき + brave なしで BattleLoop 周回 → GameOver
    // ════════════════════════════════════════════════════════════════════════

    /// $brave=false（初期値）で Battle 開始。こうげき(index 0) を選んでも
    /// クリティカル分岐に入らず「おそるおそる」→ BattleLoop に戻り続ける。
    /// 各ループで HP が 25 ずつ減るので、HP=100 → 75 → 50 → 25 → 0 で 4 周目に GameOver。
    /// 4 周目では HP<=0 が options 表示前に判定されるので、こうげき 3 回で十分。
    /// 期待: GameOver 入口の `bg gameover fade 0.8` と `se die` が発火する
    /// （brave=true 経路は GameOver には来ないので、bg gameover の存在自体が cowardly 経路の証拠）。
    @Test
    def testCowardlyAttackEventuallyGameOver(): Unit \ {Assert, IO} =
        let loaded = TestStoryFixture.loadProject();
        let events = region rc {
            let vm = Yarn.VM.init(rc, loaded, "Battle");
            // 初期値 $brave=false のままなので preset 不要
            // こうげき(0) を 3 回。4 周目に入るとき HP=0 で GameOver に飛ぶ。
            runScenario(vm, 0 :: 0 :: 0 :: Nil, 1500)
        };
        let hasGameOverBg = containsCommand("bg gameover fade 0.8", events);
        let hasDieSe = containsCommand("se die", events);
        Assert.assertEq(
            expected = (true, true),
            (hasGameOverBg, hasDieSe))

    /// brave なし こうげき で `<<jump BattleLoop>>` のループが起きる証拠として、
    /// `se hit`（BattleLoop 入口で毎回発火）の発火回数を数える。
    /// 内訳: detour で 1 回目 → こうげき 3 回で iter 2/3/4 → 4 回目で HP=0 になり GameOver に飛ぶ。
    /// brave=true 経路は 1 回しか se hit が出ないので、4 回出れば cowardly ループ確定。
    @Test
    def testCowardlyAttackRepeatsBattleLoop(): Unit \ {Assert, IO} =
        let loaded = TestStoryFixture.loadProject();
        let events = region rc {
            let vm = Yarn.VM.init(rc, loaded, "Battle");
            runScenario(vm, 0 :: 0 :: 0 :: Nil, 1500)
        };
        let seHitCount = List.count(
            event -> event == ScenarioEvent.Command("se hit"),
            events);
        Assert.assertEq(expected = 4, seHitCount)

    /// 戦闘で死亡した場合、GameOver の `<<stop>>` まで完走して
    /// DialogueComplete (`ScenarioEvent.Done`) に到達するはず。
    /// （ユーザー報告: 「ゲームオーバー画面にいきません そのまま止まります」）
    /// GameOver 入口 bg・タイトルへの phase 遷移・Done 終了の 3 点で完走を確認する。
    @Test
    def testCowardlyAttackReachesGameOverComplete(): Unit \ {Assert, IO} =
        let loaded = TestStoryFixture.loadProject();
        let events = region rc {
            let vm = Yarn.VM.init(rc, loaded, "Battle");
            runScenario(vm, 0 :: 0 :: 0 :: Nil, 1500)
        };
        let hasGameOverBg = containsCommand("bg gameover fade 0.8", events);
        let hasPhaseCommand = containsCommand("phase Start", events);
        let endedWithDone = List.last(events) == Some(ScenarioEvent.Done);
        Assert.assertEq(
            expected = (true, true, true),
            (hasGameOverBg, hasPhaseCommand, endedWithDone))

    /// GameOver 遷移時にドラゴンスプライトを隠さないと、その後タイトルに戻った
    /// あともドラゴンが残り続ける。Battle → BattleLoop → 死亡 → GameOver 経路で
    /// `sprite hide dragon` が発火することを確認する。
    /// （ユーザー報告: 「ドラゴンのスプライトがゲームオーバー後も表示され続けています」）
    @Test
    def testGameOverHidesDragonSprite(): Unit \ {Assert, IO} =
        let loaded = TestStoryFixture.loadProject();
        let events = region rc {
            let vm = Yarn.VM.init(rc, loaded, "Battle");
            runScenario(vm, 0 :: 0 :: 0 :: Nil, 1500)
        };
        Assert.assertEq(
            expected = true,
            containsCommand("sprite hide dragon", events))

    // ════════════════════════════════════════════════════════════════════════
    // (E) Room1 やすむ で bg_room と HP 回復
    // ════════════════════════════════════════════════════════════════════════

    /// Room1 で やすむ(index 2) を選ぶと `<<bg room fade 0.5>>` が発火し、
    /// `$hp` が +10 される（max_hp=100 でクランプ、初期 100 → 100 のまま）。
    /// 期待: コマンド列に `bg room fade 0.5` が含まれる。
    @Test
    def testRestPlaysRoomBackground(): Unit \ {Assert, IO} =
        let loaded = TestStoryFixture.loadProject();
        let events = region rc {
            let vm = Yarn.VM.init(rc, loaded, "Room1");
            runScenario(vm, 2 :: 2 :: Nil, 200)
        };
        Assert.assertEq(
            expected = true,
            containsCommand("bg room fade 0.5", events))

    /// HP が max を超えていないときは やすむ で +10 される。
    /// $hp=70 にプリセットして やすむ → 80 になる。
    @Test
    def testRestRecoversHp(): Unit \ {Assert, IO} =
        let hpAfter = region rc {
            let loaded = TestStoryFixture.loadProject();
            let vm = Yarn.VM.init(rc, loaded, "Room1");
            Yarn.VariableStorage.set("\$hp", FloatV(70.0), vm#variables);
            // やすむ 1 回分だけ進めて打ち切り。jump Room1 で Room1 入口の処理が
            // 回って 2 回目の選択肢に来る前後で打ち切るので 200 ステップで充分。
            discard runScenario(vm, 2 :: Nil, 200);
            Yarn.VariableStorage.get("\$hp", vm#variables)
        };
        Assert.assertEq(expected = Some(FloatV(80.0)), hpAfter)

    /// HP がほぼ満タン (95) で やすむ と +10 で 105 になるはずだが、
    /// `<<if $hp > $max_hp>><<set $hp = $max_hp>><<endif>>` で 100 にクランプされる。
    @Test
    def testRestCapsHpAtMax(): Unit \ {Assert, IO} =
        let hpAfter = region rc {
            let loaded = TestStoryFixture.loadProject();
            let vm = Yarn.VM.init(rc, loaded, "Room1");
            Yarn.VariableStorage.set("\$hp", FloatV(95.0), vm#variables);
            discard runScenario(vm, 2 :: Nil, 200);
            Yarn.VariableStorage.get("\$hp", vm#variables)
        };
        Assert.assertEq(expected = Some(FloatV(100.0)), hpAfter)

    // ════════════════════════════════════════════════════════════════════════
    // (F) Room1 たからばこ初回で 鍵を入手
    // ════════════════════════════════════════════════════════════════════════

    /// Room1 で たからばこ(index 0) を選ぶと ChestNode へ。
    /// `$chest_opened=false` 初期値なので: chest closed → se chest_open → wait → chest open
    /// → item add key の順で発火する。
    @Test
    def testChestFirstTimeGivesKey(): Unit \ {Assert, IO} =
        let loaded = TestStoryFixture.loadProject();
        let events = region rc {
            let vm = Yarn.VM.init(rc, loaded, "Room1");
            runScenario(vm, 0 :: 2 :: Nil, 300)
        };
        let cmds = commandsOf(events);
        let expected: List[String] =
            "sprite show chest closed" ::
            "se chest_open" ::
            "wait 0.4" ::
            "sprite show chest open" ::
            "item add key" ::
            Nil;
        // 後続のループで「sprite show chest open」が default 選択肢で繰り返し出るので、
        // 先頭 5 件（= 期待のシーケンス長）だけを比較する。
        let firstMatches = List.take(
            List.length(expected),
            List.filter(s -> List.memberOf(s, expected), cmds));
        Assert.assertEq(expected = expected, firstMatches)

    /// たからばこを開けると `$inv_key=true` と `$chest_opened=true` がセットされる。
    @Test
    def testChestFirstTimeSetsKeyAndOpenedFlags(): Unit \ {Assert, IO} =
        let (keyVal, openedVal) = region rc {
            let loaded = TestStoryFixture.loadProject();
            let vm = Yarn.VM.init(rc, loaded, "Room1");
            discard runScenario(vm, 0 :: 2 :: Nil, 300);
            (Yarn.VariableStorage.get("\$inv_key", vm#variables),
             Yarn.VariableStorage.get("\$chest_opened", vm#variables))
        };
        Assert.assertEq(
            expected = (Some(BoolV(true)), Some(BoolV(true))),
            (keyVal, openedVal))

    // ════════════════════════════════════════════════════════════════════════
    // (G) Room1 たからばこ 2 回目は からっぽ
    // ════════════════════════════════════════════════════════════════════════

    /// $chest_opened=true をプリセットして Room1 → たからばこ を選ぶと、
    /// 「closed → se chest_open → wait → open」の else 経路は走らない。
    /// closed sprite は else 経路にしかないので、`sprite show chest closed` が
    /// 出ない & `se chest_open` / `item add key` も出ないことで「からっぽ」経路を確定する。
    @Test
    def testChestSecondTimeIsEmpty(): Unit \ {Assert, IO} =
        let loaded = TestStoryFixture.loadProject();
        let events = region rc {
            let vm = Yarn.VM.init(rc, loaded, "Room1");
            Yarn.VariableStorage.set("\$chest_opened", BoolV(true), vm#variables);
            runScenario(vm, 0 :: 2 :: Nil, 300)
        };
        let hasShowChestClosed = containsCommand("sprite show chest closed", events);
        let hasChestOpenSe = containsCommand("se chest_open", events);
        let hasItemAddKey = containsCommand("item add key", events);
        Assert.assertEq(
            expected = (false, false, false),
            (hasShowChestClosed, hasChestOpenSe, hasItemAddKey))

    // ════════════════════════════════════════════════════════════════════════
    // (H) Room1 とびら 鍵なしで locked + shake
    // ════════════════════════════════════════════════════════════════════════

    /// Room1 で とびら(index 1) を鍵なし状態（$inv_key=false 初期値）で選ぶと、
    /// `<<se locked>>` と `<<shake 0.3>>` が発火し、再び Room1 に戻る。
    @Test
    def testLockedDoorWithoutKey(): Unit \ {Assert, IO} =
        let loaded = TestStoryFixture.loadProject();
        let events = region rc {
            let vm = Yarn.VM.init(rc, loaded, "Room1");
            runScenario(vm, 1 :: 2 :: Nil, 300)
        };
        let hasLocked = containsCommand("se locked", events);
        let hasShake = containsCommand("shake 0.3", events);
        Assert.assertEq(expected = (true, true), (hasLocked, hasShake))

    // ════════════════════════════════════════════════════════════════════════
    // (I) Room1 とびら 鍵ありで Battle に進む
    // ════════════════════════════════════════════════════════════════════════

    /// $inv_key=true にして Room1 で とびら(index 1) を選ぶと、
    /// `<<se door_open>>` が発火し、Battle に jump して `bg boss fade 0.3` が来る。
    @Test
    def testOpenDoorWithKeyJumpsToBattle(): Unit \ {Assert, IO} =
        let loaded = TestStoryFixture.loadProject();
        let events = region rc {
            let vm = Yarn.VM.init(rc, loaded, "Room1");
            Yarn.VariableStorage.set("\$inv_key", BoolV(true), vm#variables);
            runScenario(vm, 1 :: 1 :: 2 :: Nil, 500)
        };
        let hasDoorOpen = containsCommand("se door_open", events);
        let hasBossBg = containsCommand("bg boss fade 0.3", events);
        Assert.assertEq(expected = (true, true), (hasDoorOpen, hasBossBg))

    // ════════════════════════════════════════════════════════════════════════
    // (J) Intro 名前選択で $player_name がセットされる
    // ════════════════════════════════════════════════════════════════════════

    /// Intro でアレフ(index 0) → はい(index 0) を選ぶと `$player_name = "アレフ"`
    /// と `$brave = true` がセットされる。Room1 まで進んだあと打ち切る。
    @Test
    def testIntroAlephSetsPlayerName(): Unit \ {Assert, IO} =
        let nameVal = region rc {
            let loaded = TestStoryFixture.loadProject();
            let vm = Yarn.VM.init(rc, loaded, "Intro");
            // 名前=アレフ(0) → ゆうかん=はい(0) → Room1 で やすむ(2) で終端ループへ
            discard runScenario(vm, 0 :: 0 :: 2 :: Nil, 500);
            Yarn.VariableStorage.get("\$player_name", vm#variables)
        };
        Assert.assertEq(expected = Some(StringV("アレフ")), nameVal)

    /// Intro でベータ(index 1) を選ぶと `$player_name = "ベータ"`。
    @Test
    def testIntroBetaSetsPlayerName(): Unit \ {Assert, IO} =
        let nameVal = region rc {
            let loaded = TestStoryFixture.loadProject();
            let vm = Yarn.VM.init(rc, loaded, "Intro");
            // 名前=ベータ(1) → ゆうかん=はい(0) → Room1 で やすむ(2)
            discard runScenario(vm, 1 :: 0 :: 2 :: Nil, 500);
            Yarn.VariableStorage.get("\$player_name", vm#variables)
        };
        Assert.assertEq(expected = Some(StringV("ベータ")), nameVal)

    // ════════════════════════════════════════════════════════════════════════
    // (K) Intro はい / いいえ で $brave がセットされる
    // ════════════════════════════════════════════════════════════════════════

    /// はい(index 0) → `$brave = true` がセットされる。
    /// （台詞テキストの差異は line ハッシュ依存なのでテスト対象にしない）
    @Test
    def testIntroBraveYesSetsTrue(): Unit \ {Assert, IO} =
        let braveVal = region rc {
            let loaded = TestStoryFixture.loadProject();
            let vm = Yarn.VM.init(rc, loaded, "Intro");
            discard runScenario(vm, 0 :: 0 :: 2 :: Nil, 500);
            Yarn.VariableStorage.get("\$brave", vm#variables)
        };
        Assert.assertEq(expected = Some(BoolV(true)), braveVal)

    /// いいえ(index 1) → `$brave = false` がセットされる。
    @Test
    def testIntroBraveNoSetsFalse(): Unit \ {Assert, IO} =
        let braveVal = region rc {
            let loaded = TestStoryFixture.loadProject();
            let vm = Yarn.VM.init(rc, loaded, "Intro");
            discard runScenario(vm, 0 :: 1 :: 2 :: Nil, 500);
            Yarn.VariableStorage.get("\$brave", vm#variables)
        };
        Assert.assertEq(expected = Some(BoolV(false)), braveVal)

    // ════════════════════════════════════════════════════════════════════════
    // (L) Ending では save / bgm fade が発火（brave 別の台詞テキストは
    //     line ハッシュ依存なのでテスト対象にしない）
    // ════════════════════════════════════════════════════════════════════════

    /// Ending では `<<save 1>>` と `<<bgm fade 2.0>>` が発火する。
    @Test
    def testEndingFiresSaveAndBgmFade(): Unit \ {Assert, IO} =
        let loaded = TestStoryFixture.loadProject();
        let events = region rc {
            let vm = Yarn.VM.init(rc, loaded, "Ending");
            runScenario(vm, Nil, 500)
        };
        Assert.assertEq(
            expected = (true, true),
            (containsCommand("save 1", events),
             containsCommand("bgm fade 2.0", events)))

    // ════════════════════════════════════════════════════════════════════════
    // (M) GameOver で die SE と phase Start が発火
    // ════════════════════════════════════════════════════════════════════════

    /// GameOver ノードを直接実行して、`bg gameover fade 0.8`、`bgm fade 0.5`、
    /// `se die`、最後に `phase Start` が発火し、`<<stop>>` で DialogueComplete に
    /// 到達することを確認する。
    @Test
    def testGameOverFiresExpectedCommands(): Unit \ {Assert, IO} =
        let loaded = TestStoryFixture.loadProject();
        let events = region rc {
            let vm = Yarn.VM.init(rc, loaded, "GameOver");
            runScenario(vm, Nil, 500)
        };
        let bgGameover = containsCommand("bg gameover fade 0.8", events);
        let bgmFade = containsCommand("bgm fade 0.5", events);
        let seDie = containsCommand("se die", events);
        let phaseStart = containsCommand("phase Start", events);
        let endedCleanly = List.last(events) == Some(ScenarioEvent.Done);
        Assert.assertEq(
            expected = (true, true, true, true, true),
            (bgGameover, bgmFade, seDie, phaseStart, endedCleanly))

    // ════════════════════════════════════════════════════════════════════════
    // (N) MeetKing セーブポイント
    // ════════════════════════════════════════════════════════════════════════

    /// MeetKing 入口で `bg dungeon fade 0.3` / `bgm play dungeon loop` /
    /// `sprite show ou center` の 3 点セットが発火する（Intro と同じ演出を
    /// セーブポイントでも再現していることの確認）。
    /// 選択肢は「やめておく」(index 1) を選んで素直に抜ける。
    @Test
    def testMeetKingEntryShowsKingInDungeon(): Unit \ {Assert, IO} =
        let loaded = TestStoryFixture.loadProject();
        let events = region rc {
            let vm = Yarn.VM.init(rc, loaded, "MeetKing");
            runScenario(vm, 1 :: 2 :: Nil, 300)
        };
        Assert.assertEq(
            expected = (true, true, true),
            (containsCommand("bg dungeon fade 0.3", events),
             containsCommand("bgm play dungeon loop", events),
             containsCommand("sprite show ou center", events)))

    /// 「セーブする」(index 0) を選ぶと `save 1` が発火し、退出時に
    /// `sprite hide ou` で王スプライトが消える（画面に残らない）。
    @Test
    def testMeetKingSaveOptionFiresSaveAndHidesKing(): Unit \ {Assert, IO} =
        let loaded = TestStoryFixture.loadProject();
        let events = region rc {
            let vm = Yarn.VM.init(rc, loaded, "MeetKing");
            // セーブする(0) → Room1 に戻り やすむ(2) で打ち切り
            runScenario(vm, 0 :: 2 :: Nil, 300)
        };
        Assert.assertEq(
            expected = (true, true),
            (containsCommand("save 1", events),
             containsCommand("sprite hide ou", events)))

    /// 「やめておく」(index 1) では `save 1` が発火しない。
    /// セーブをスキップする経路でも `sprite hide ou` で王は消える。
    @Test
    def testMeetKingSkipOptionDoesNotSaveButHidesKing(): Unit \ {Assert, IO} =
        let loaded = TestStoryFixture.loadProject();
        let events = region rc {
            let vm = Yarn.VM.init(rc, loaded, "MeetKing");
            // やめておく(1) → Room1 に戻り やすむ(2) で打ち切り
            runScenario(vm, 1 :: 2 :: Nil, 300)
        };
        Assert.assertEq(
            expected = (false, true),
            (containsCommand("save 1", events),
             containsCommand("sprite hide ou", events)))

    /// MeetKing から Room1 に戻ると Room1 入口の `bg room1 fade 0.5` と
    /// `bgm play room loop` が再発火する（dungeon 系の bg/bgm が残らないこと）。
    @Test
    def testMeetKingExitRestoresRoom1Scene(): Unit \ {Assert, IO} =
        let loaded = TestStoryFixture.loadProject();
        let events = region rc {
            let vm = Yarn.VM.init(rc, loaded, "MeetKing");
            runScenario(vm, 1 :: 2 :: Nil, 300)
        };
        Assert.assertEq(
            expected = (true, true),
            (containsCommand("bg room1 fade 0.5", events),
             containsCommand("bgm play room loop", events)))

    /// Room1 の新選択肢「王に あいに いく」(index 3) を選ぶと MeetKing に
    /// jump して入口の `sprite show ou center` が発火する（選択肢配線の確認）。
    @Test
    def testRoom1MeetKingChoiceJumpsToMeetKing(): Unit \ {Assert, IO} =
        let loaded = TestStoryFixture.loadProject();
        let events = region rc {
            let vm = Yarn.VM.init(rc, loaded, "Room1");
            // 王に あいに いく(3) → MeetKing で やめておく(1) → Room1 で やすむ(2)
            runScenario(vm, 3 :: 1 :: 2 :: Nil, 500)
        };
        Assert.assertEq(
            expected = true,
            containsCommand("sprite show ou center", events))

    /// `<<load>>` 後は変数 `$_loaded_at_meet_king=true` が復元された状態で
    /// MeetKing に再入する。このときは「おかえり」分岐に入り、save ダイアログを
    /// 出さずにそのまま部屋を出る（`save 1` は発火せず、`sprite hide ou` で退出）。
    @Test
    def testMeetKingAfterLoadExitsWithoutSavePrompt(): Unit \ {Assert, IO} =
        let loaded = TestStoryFixture.loadProject();
        let events = region rc {
            let vm = Yarn.VM.init(rc, loaded, "MeetKing");
            Yarn.VariableStorage.set("\$_loaded_at_meet_king", BoolV(true), vm#variables);
            // 選択肢が出ない経路なので index 列なし。Room1 復帰後 やすむ(2) で打ち切り。
            runScenario(vm, 2 :: Nil, 300)
        };
        Assert.assertEq(
            expected = (false, true),
            (containsCommand("save 1", events),
             containsCommand("sprite hide ou", events)))

    /// 「おかえり」経路を抜けたあとは `$_loaded_at_meet_king` が false に戻る。
    /// （再びこの部屋を訪れた場合は通常通り save ダイアログが出る）
    @Test
    def testMeetKingAfterLoadResetsLoadedFlag(): Unit \ {Assert, IO} =
        let flagAfter = region rc {
            let loaded = TestStoryFixture.loadProject();
            let vm = Yarn.VM.init(rc, loaded, "MeetKing");
            Yarn.VariableStorage.set("\$_loaded_at_meet_king", BoolV(true), vm#variables);
            discard runScenario(vm, 2 :: Nil, 300);
            Yarn.VariableStorage.get("\$_loaded_at_meet_king", vm#variables)
        };
        Assert.assertEq(expected = Some(BoolV(false)), flagAfter)
}
