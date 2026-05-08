/// Save / Load 機能のテスト。
///
/// Phase A: VM 抽象拡張（VariableStorage.toMap / VariableAccess.snapshot /
///   Session.restart）の動作確認。
/// Phase B: Game.SaveManager の write / read のラウンドトリップとファイル形式。
/// CommandRouter 配線は Phase C で別途。
///
/// ディスク I/O テストはスロット 999 を専用に使い、各テスト冒頭で
/// `saves/slot999.json` を削除してから走らせる前提（並列実行しない）。
mod TestSaveLoad {
    use Yarn.Types.{YarnProject, Value}
    use Yarn.Types.Value.{BoolV, FloatV, StringV}
    use Game.SaveManager.SaveData

    /// テスト用の固定スロット番号。本番のスロット 1 と衝突させない。
    def testSlot(): Int32 = 999

    /// `Yarn.VariableAccess.currentNode()` / `variableSnapshot()` が現在ノード名と
    /// 全変数を返すか。
    /// Room1 で開始 → `$inv_key=true` をセット → snapshot を取って中身を確認。
    /// region 外に持ち出す値は文字列に正規化（None → ""）して Eq インスタンス問題を回避。
    @Test
    def testSnapshotReturnsCurrentNodeAndVariables(): Unit \ {Assert, IO} =
        let compiledProject = TestStoryFixture.loadProject();
        let (nodeName, invKeyTrue) = region rc {
            let nodeStringRef = Ref.fresh(rc, "");
            let hasInvKey = Ref.fresh(rc, false);
            let _ = Dialogue.StubView.withRecordingView(rc, () -> {
                run {
                    Dialogue.Session.start("Room1");
                    Yarn.VariableAccess.setBool("\$inv_key", true);
                    let nodeOpt = Yarn.VariableAccess.currentNode();
                    Ref.put(Option.getWithDefault("", nodeOpt), nodeStringRef);
                    let vars = Yarn.VariableAccess.variableSnapshot();
                    let isTrue = match Map.get("\$inv_key", vars) {
                        case Some(BoolV(b)) => b
                        case _              => false
                    };
                    Ref.put(isTrue, hasInvKey)
                } with Dialogue.Runner.withRunner(rc, compiledProject)
                  with Dialogue.Commands.withWaitOnly
            });
            (Ref.get(nodeStringRef), Ref.get(hasInvKey))
        };
        Assert.assertEq(expected = ("Room1", true), (nodeName, invKeyTrue))

    /// VM 未開始のときは currentNode=None / variableSnapshot は空 Map。
    @Test
    def testSnapshotIsEmptyBeforeStart(): Unit \ {Assert, IO} =
        let compiledProject = TestStoryFixture.loadProject();
        let (nodeIsNone, varsEmpty) = region rc {
            let nodeIsNoneRef = Ref.fresh(rc, false);
            let isEmptyRef = Ref.fresh(rc, false);
            let _ = Dialogue.StubView.withRecordingView(rc, () -> {
                run {
                    // Session.start を呼ばずに即 snapshot
                    Ref.put(Option.isEmpty(Yarn.VariableAccess.currentNode()), nodeIsNoneRef);
                    let vars = Yarn.VariableAccess.variableSnapshot();
                    Ref.put(Map.isEmpty(vars), isEmptyRef)
                } with Dialogue.Runner.withRunner(rc, compiledProject)
                  with Dialogue.Commands.withWaitOnly
            });
            (Ref.get(nodeIsNoneRef), Ref.get(isEmptyRef))
        };
        Assert.assertEq(expected = (true, true), (nodeIsNone, varsEmpty))

    /// `Session.restart(node, vars)` で新 VM が立ち上がり、変数が復元され、
    /// ノード冒頭の処理がそのまま走ることを確認する。
    /// Battle で開始した VM を、変数を持たせて Ending に restart →
    /// 1) Ending 冒頭の line に置換された $player_name "テスト" が現れる
    /// 2) submitNext で進めて brave=true 用の "しんの ゆうしゃ" line が出る
    @Test
    def testRestartInitsNewVmWithVariables(): Unit \ {Assert, IO} =
        let compiledProject = TestStoryFixture.loadProject();
        let log = region rc {
            let (_, viewLog) = Dialogue.StubView.withRecordingView(rc, () -> {
                run {
                    Dialogue.Session.start("Battle");
                    // Battle 経路を捨てて Ending を $brave=true で最初から再生
                    Dialogue.Session.restart("Ending",
                        Map#{"\$brave" => BoolV(true), "\$player_name" => StringV("テスト")});
                    // brave 分岐は冒頭から数行進んだところに出るので tap を 2 回送る
                    Dialogue.Session.submitNext();
                    Dialogue.Session.submitNext()
                } with Dialogue.Runner.withRunner(rc, compiledProject)
                  with Dialogue.Commands.withWaitOnly
            });
            viewLog
        };
        let hasRestoredName = List.exists(event -> match event {
            case Dialogue.ViewEvent.Line(text, _) =>
                String.contains({substr = "テスト"}, text)
            case _ => false
        }, log);
        let hasTrueHero = List.exists(event -> match event {
            case Dialogue.ViewEvent.Line(text, _) =>
                String.contains({substr = "しんの ゆうしゃ"}, text)
            case _ => false
        }, log);
        Assert.assertEq(expected = (true, true), (hasRestoredName, hasTrueHero))

    // ════════════════════════════════════════════════════════════════════════
    // Phase B: Game.SaveManager のディスク I/O とラウンドトリップ
    // ════════════════════════════════════════════════════════════════════════

    /// 指定スロットのセーブファイルが存在しても消す。File が無くても DeleteFile は
    /// エラーで返るがその場合は無視（`Result` の Err は単に「消すものが無い」）。
    def deleteSlotFile(slot: Int32): Unit \ Fs.FileWrite =
        let path = Game.SaveManager.slotPath(slot);
        let _ = run {
            Fs.DeleteFile.delete(path)
        } with Fs.DeleteFile.runWithFileWrite;
        ()

    /// TC2: write → read で同じ SaveData が返ってくる（ラウンドトリップ）。
    @Test
    def testSaveLoadRoundtrip(): Unit \ {Assert, IO} =
        let data = SaveData.SaveData("Ending", Map#{
            "\$brave"       => BoolV(true),
            "\$hp"          => FloatV(75.0),
            "\$player_name" => StringV("テスト")
        });
        let loaded = run {
            deleteSlotFile(testSlot());
            match Game.SaveManager.write(testSlot(), data) {
                case Ok(_)    => ()
                case Err(msg) => bug!("write failed: ${msg}")
            };
            Game.SaveManager.read(testSlot())
        } with Fs.FileRead.runWithIO
          with Fs.FileWrite.runWithIO;
        Assert.assertEq(expected = Some(data), loaded)

    /// TC3: 存在しないスロットを read すると None が返る。
    @Test
    def testReadMissingSlotReturnsNone(): Unit \ {Assert, IO} =
        let loaded = run {
            deleteSlotFile(testSlot());
            Game.SaveManager.read(testSlot())
        } with Fs.FileRead.runWithIO
          with Fs.FileWrite.runWithIO;
        Assert.assertEq(expected = (None: Option[SaveData]), loaded)

    /// TC4: 書き出された JSON は output.json と同じ value 表現
    /// （`boolValue` / `floatValue` / `stringValue` のキー）を含む。
    /// 形式ドリフトの早期検出用。
    @Test
    def testWrittenJsonMatchesOutputShape(): Unit \ {Assert, IO} =
        let data = SaveData.SaveData("Ending", Map#{
            "\$brave"       => BoolV(true),
            "\$hp"          => FloatV(50.0),
            "\$player_name" => StringV("テスト")
        });
        let text = run {
            deleteSlotFile(testSlot());
            match Game.SaveManager.write(testSlot(), data) {
                case Ok(_)    => ()
                case Err(msg) => bug!("write failed: ${msg}")
            };
            let path = Game.SaveManager.slotPath(testSlot());
            let r = run { Fs.ReadFile.read(path) } with Fs.ReadFile.runWithFileRead;
            Result.getWithDefault("", r)
        } with Fs.FileRead.runWithIO
          with Fs.FileWrite.runWithIO;
        let hasBoolKey   = String.contains({substr = "\"boolValue\""},   text);
        let hasFloatKey  = String.contains({substr = "\"floatValue\""},  text);
        let hasStringKey = String.contains({substr = "\"stringValue\""}, text);
        let hasNodeKey   = String.contains({substr = "\"node\""},        text);
        Assert.assertEq(
            expected = (true, true, true, true),
            (hasBoolKey, hasFloatKey, hasStringKey, hasNodeKey))

    /// TC5: CommandRouter 経由で `<<save N>>` `<<load N>>` を実行する end-to-end
    /// テスト。本番と同じ runner/asyncOnly/sceneView 構成に CommandRouter を
    /// 1 フレーム回し、save 後にディスクに書かれていること、別 region で load
    /// すれば Session が復元されること（変数が反映されたセリフが出ること）を確認。
    @Test
    def testSaveLoadViaCommandRouter(): Unit \ {Assert, IO} =
        let compiledProject = TestStoryFixture.loadProject();
        // ── ステップ 1: Ending を $brave=true / $player_name="セーブ" で開始
        //    → save 1 コマンドが CommandRouter 経由で発火 → ディスクに書く
        region rc {
            let scene: Scene[NodeTag] = Scene.empty();
            run {
                Dialogue.Session.restart("Ending",
                    Map#{"\$brave" => BoolV(true),
                         "\$player_name" => StringV("セーブ")});
                // Ending: bg → bgm play → Line × 3（よくぞ／しんの／たびの）
                // → <<save 1>> → Line（セーブしました）→ ...
                // Line 3 つ進めれば <<save 1>> が走る
                discard driveFrames(scene, 5);
                Dialogue.Session.submitNext();
                discard driveFrames(scene, 5);
                Dialogue.Session.submitNext();
                discard driveFrames(scene, 5);
                Dialogue.Session.submitNext();
                discard driveFrames(scene, 10)
            } with Dialogue.Runner.withRunner(rc, compiledProject)
              with Dialogue.Commands.withAsyncOnly
              with Dialogue.SceneView.withSceneView(rc)
              with Fs.FileRead.runWithIO
              with Fs.FileWrite.runWithIO
              with Game.ShakeState.withState(rc)
              with Game.AudioFader.withState(rc)
              with Game.CommandWaitQueue.withState(rc)
              with handler GameEngine.Audio {
                def playAudio(_n, k) = k(())
                def stopAudio(_n, k) = k(())
                def setVolume(_n, _v, k) = k(())
              }
        };
        // ── ステップ 2: 別 region で load → Ending が再生され、$brave=true /
        //    $player_name="セーブ" の世界線で「しんの ゆうしゃ」line が出る
        let log = region rc {
            let scene: Scene[NodeTag] = Scene.empty();
            let viewLog = Ref.fresh(rc, (Nil: List[Dialogue.ViewEvent]));
            run {
                Dialogue.Session.start("Start");
                // Start のオプションで「つづきから」(index 1) を選んで <<load 1>>
                discard driveFramesRecording(viewLog, scene, 1, 50)
            } with Dialogue.Runner.withRunner(rc, compiledProject)
              with Dialogue.Commands.withAsyncOnly
              with Dialogue.SceneView.withSceneView(rc)
              with Fs.FileRead.runWithIO
              with Fs.FileWrite.runWithIO
              with Game.ShakeState.withState(rc)
              with Game.AudioFader.withState(rc)
              with Game.CommandWaitQueue.withState(rc)
              with handler GameEngine.Audio {
                def playAudio(_n, k) = k(())
                def stopAudio(_n, k) = k(())
                def setVolume(_n, _v, k) = k(())
              };
            Ref.get(viewLog) |> List.reverse
        };
        // 期待: load 後の Ending で「しんの ゆうしゃ」line が出ている
        let hasTrueHero = List.exists(event -> match event {
            case Dialogue.ViewEvent.Line(text, _) =>
                String.contains({substr = "しんの ゆうしゃ"}, text)
            case _ => false
        }, log);
        Assert.assertEq(expected = true, hasTrueHero)

    /// TC6: セーブが無い状態で `<<load 999>>` が発火しても、
    /// CommandRouter が `$_load_failed = true` をセットして story を進めるので、
    /// 旧 VM 側の story が分岐ロジックでメッセージを出して title に戻れる。
    /// （Phase C の「セーブ無し時の分岐」回帰テスト）
    @Test
    def testLoadWithoutSaveFlagsLoadFailed(): Unit \ {Assert, IO} =
        let compiledProject = TestStoryFixture.loadProject();
        let log = region rc {
            let scene: Scene[NodeTag] = Scene.empty();
            let viewLog = Ref.fresh(rc, (Nil: List[Dialogue.ViewEvent]));
            run {
                // 直前テストの保存物が残っていると <<load 1>> が成功してしまうので
                // saves/slot1.json を確実に消してから走らせる。
                deleteSlotFile(1);
                Dialogue.Session.start("Start");
                // つづきから (index 1) を選んで `<<load 1>>` が走るが
                // saves/slot1.json は冒頭で消し済みなので失敗する。
                // story.yarn の `$_load_failed` 分岐が「ありません」line を
                // 出して `<<jump Start>>` で先頭に戻すはず。
                discard driveFramesRecording(viewLog, scene, 1, 50)
            } with Dialogue.Runner.withRunner(rc, compiledProject)
              with Dialogue.Commands.withAsyncOnly
              with Dialogue.SceneView.withSceneView(rc)
              with Fs.FileRead.runWithIO
              with Fs.FileWrite.runWithIO
              with Game.ShakeState.withState(rc)
              with Game.AudioFader.withState(rc)
              with Game.CommandWaitQueue.withState(rc)
              with handler GameEngine.Audio {
                def playAudio(_n, k) = k(())
                def stopAudio(_n, k) = k(())
                def setVolume(_n, _v, k) = k(())
              };
            Ref.get(viewLog) |> List.reverse
        };
        // 期待: 「セーブデータが ありません」line が出ている（story 側分岐の証跡）
        let hasNoSaveLine = List.exists(event -> match event {
            case Dialogue.ViewEvent.Line(text, _) =>
                String.contains({substr = "セーブデータ"}, text)
            case _ => false
        }, log);
        Assert.assertEq(expected = true, hasNoSaveLine)

    /// 1 フレーム = inbox を drain して view イベントを log に積む + line/choice
    /// で次へ進める + processCommands を 1 回回す、これを `framesLeft` 回。
    /// 選択肢に当たったら `choice` の値を選ぶ（複数選択肢ならどれにも同じ index）。
    def driveFramesRecording(viewLog: Ref[List[Dialogue.ViewEvent], r],
                              scene: Scene[NodeTag],
                              choice: Int32,
                              framesLeft: Int32):
                              Scene[NodeTag] \ {
                                Dialogue.SceneView.Inbox, Dialogue.SceneView.CommandInbox,
                                Dialogue.Session, Yarn.VariableAccess,
                                Game.CommandWaitQueue.Access,
                                Game.ShakeState.Access,
                                Game.AudioFader.Access,
                                GameEngine.Audio, Fs.FileRead, Fs.FileWrite, IO, r
                              } =
        if (framesLeft <= 0) scene
        else {
            let viewEvents = Dialogue.SceneView.Inbox.takeAll();
            List.forEach(event -> {
                Ref.put(event :: Ref.get(viewLog), viewLog);
                match event {
                    case Dialogue.ViewEvent.Line(_, _) =>
                        Dialogue.Session.submitNext()
                    case Dialogue.ViewEvent.Choices(_) =>
                        Dialogue.Session.submitSelect(choice)
                    case _ => ()
                }
            }, viewEvents);
            let next = Game.CommandRouter.processCommands(
                delta = Duration.seconds(0.1), scene);
            driveFramesRecording(viewLog, next, choice, framesLeft - 1)
        }

    /// `driveFramesRecording` の view 記録なし版。save テストで
    /// 「とにかく story を進める」だけに使う。
    def driveFrames(scene: Scene[NodeTag], framesLeft: Int32):
                     Scene[NodeTag] \ {
                       Dialogue.SceneView.Inbox, Dialogue.SceneView.CommandInbox,
                       Dialogue.Session, Yarn.VariableAccess,
                       Game.CommandWaitQueue.Access,
                       Game.ShakeState.Access,
                       Game.AudioFader.Access,
                       GameEngine.Audio, Fs.FileRead, Fs.FileWrite, IO
                     } =
        if (framesLeft <= 0) scene
        else {
            let viewEvents = Dialogue.SceneView.Inbox.takeAll();
            List.forEach(event -> match event {
                case Dialogue.ViewEvent.Line(_, _)    => Dialogue.Session.submitNext()
                case Dialogue.ViewEvent.Choices(_)    => Dialogue.Session.submitSelect(0)
                case _ => ()
            }, viewEvents);
            let next = Game.CommandRouter.processCommands(
                delta = Duration.seconds(0.1), scene);
            driveFrames(next, framesLeft - 1)
        }
}
