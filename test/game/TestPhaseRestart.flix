/// 戦闘で死亡した直後の `<<phase Start>>` がタイトル画面へ戻すかを検証する統合テスト。
///
/// VM レベル単体（`TestStoryScenario`）では `<<phase>>` は単なる Command として
/// 通過するだけだが、ユーザーから見ると「GameOver 後にタイトルに戻る」のが
/// 期待挙動。ここでは Dialogue.Runner / SceneView / CommandRouter / WaitQueue を
/// 本番と同じ構成で組んで、`<<phase Start>>` が実際に Session を再起動するか
/// を確認する。
///
/// 観測点: GameOver を流し切ったあと `bgm play title loop` などタイトル側
/// コマンドが（再）発火しているか、を Audio handler で記録して判定する。
mod TestPhaseRestart {
    use Yarn.Types.YarnProject

    /// 本番と同じパイプラインを 1 フレーム分回すドライバー。
    /// (1) View Inbox を drain して Line/Choices/Complete を logRef に積む
    /// (2) Line なら自動 tap (submitNext)、Choices なら index 0 を選択
    /// (3) `Game.CommandRouter.processCommands` で commandQueue を流し、
    ///     `<<wait>>` も `WaitQueue.tick` で進める
    /// (4) `framesLeft` 回ループ
    def drive(viewLog: Ref[List[Dialogue.ViewEvent], r],
                scene: Scene[NodeTag],
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
                        Dialogue.Session.submitSelect(0)
                    case _ => ()
                }
            }, viewEvents);
            // dt = 0.1s／frame として `<<wait 1.0>>` は 10 frame で進む
            let next = Game.CommandRouter.processCommands(
                delta = Duration.seconds(0.1), scene);
            drive(viewLog, next, framesLeft - 1)
        }

    /// GameOver を起点に dialogue を流し、`<<phase Start>>` 経由で
    /// タイトル側のコマンドが再発火するかを確認する。
    /// 観測点: `playAudio("title")` が呼ばれること。
    @Test
    def testGameOverReturnsToTitleViaPhaseStart(): Unit \ {Assert, IO} =
        let loaded = TestStoryFixture.loadProject();
        let titleBgmCalled = region rc {
            let viewLog = Ref.fresh(rc, (Nil: List[Dialogue.ViewEvent]));
            let playedSounds = Ref.fresh(rc, (Nil: List[String]));
            let scene: Scene[NodeTag] = Scene.empty();

            run {
                Dialogue.Session.start("GameOver");
                discard drive(viewLog, scene, 80)
            } with Dialogue.Runner.withRunner(rc, loaded)
              with Dialogue.Commands.withAsyncOnly
              with Dialogue.SceneView.withSceneView(rc)
              with Fs.FileRead.runWithIO
              with Fs.FileWrite.runWithIO
              with Game.ShakeState.withState(rc)
              with Game.AudioFader.withState(rc)
              with Game.CommandWaitQueue.withState(rc)
              with handler GameEngine.Audio {
                def playAudio(name, k) = {
                    Ref.put(name :: Ref.get(playedSounds), playedSounds);
                    k(())
                }
                def stopAudio(_name, k) = k(())
                def setVolume(_name, _vol, k) = k(())
              };
            // タイトル BGM が再生されたか
            List.memberOf("title", Ref.get(playedSounds))
        };
        Assert.assertEq(expected = true, titleBgmCalled)
}
