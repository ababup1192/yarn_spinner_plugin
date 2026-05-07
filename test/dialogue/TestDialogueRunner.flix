/// `Dialogue.Runner.withRunner` が 3 段 handler 連結（withRecordingView +
/// withWaitOnly + withRunner）の中で正しく動くことを確認するテスト。
///
/// 純粋層の VM 動作は `TestYarnScenario` で保証済み。ここでは「effect 層が
/// それを下流に正しく仲介すること」だけを検証する。
mod TestDialogueRunner {
    use Yarn.Types.YarnProject
    use Dialogue.StubView.{ViewEvent}
    use Dialogue.StubView.ViewEvent.{PresentedLine, PresentedOptions, Command, Complete}

    // fixture は `TestYarnFixture.loadProject()` 経由でインライン取得する。

    /// `withRecordingView + withWaitOnly + withRunner` を 1 つの run で連結する
    /// effect-polymorphic ヘルパー。テスト本体は `Dialog` だけを使えばよい。
    def runWithStubs(rc: Region[r], compiledProject: YarnProject,
                      body: Unit -> Unit \ Dialogue.Dialog):
                      List[ViewEvent] \ r =
        let (_, log) = Dialogue.StubView.withRecordingView(rc, () -> {
            Dialogue.Commands.withWaitOnly(() -> {
                Dialogue.Runner.withRunner(rc, compiledProject, body)
            })
        });
        log

    // ========================================================================
    // start → 「はい」確定 → 完走までのイベント列
    // ========================================================================

    /// `Dialog.start("Start")` してから「はい」（index 0）を確定すると、
    /// VM が wait コマンドを通って DialogueComplete に到達する。
    /// view 側で受け取るイベントの並びを 1 度に検証する。
    @Test
    def testYesChoiceFlowsThroughView(): Unit \ Assert =
        let compiledProject = TestYarnFixture.loadProject();
        let events = region rc {
            runWithStubs(rc, compiledProject, () -> {
                Dialogue.Dialog.start("Start");          // → presentLine(おう: ゆうしゃよ…)
                Dialogue.Dialog.submitAdvance();         // → presentLine(まおうを…)
                Dialogue.Dialog.submitAdvance();         // → presentOptions([はい, いいえ])
                Dialogue.Dialog.submitSelect(0);         // → presentLine(たのもしいぞ)
                Dialogue.Dialog.submitAdvance();         // → presentLine(HPは 0 ある)
                Dialogue.Dialog.submitAdvance();         // → runCommand("wait 0.5") → 自動完了
                                                          //   → presentLine(たびだちじゃ)
                Dialogue.Dialog.submitAdvance()           // → dialogueComplete
            })
        };
        let expected: List[ViewEvent] =
            PresentedLine("おう: ゆうしゃよ、よくぞ もどった！") ::
            PresentedLine("おう: まおうを たおすのじゃ。") ::
            PresentedOptions("はい" :: "いいえ" :: Nil) ::
            PresentedLine("おう: たのもしいぞ。") ::
            PresentedLine("おう: ＨＰは 0 ある。 きをつけてゆけ！") ::
            Command("wait 0.5") ::
            PresentedLine("おう: …では、たびだちじゃ。") ::
            Complete :: Nil;
        Assert.assertEq(expected = expected, events)

    // ========================================================================
    // 「いいえ」を選んだら Start に再帰し、最初の行が再表示される
    // ========================================================================

    /// 「いいえ」を選ぶと `runNode Start` で先頭に戻るので、
    /// 先頭の `おう: ゆうしゃよ…` が 2 度提示される。
    /// 2 度目の表示まで進めて確認する。
    @Test
    def testNoChoiceRecursesToStart(): Unit \ Assert =
        let compiledProject = TestYarnFixture.loadProject();
        let events = region rc {
            runWithStubs(rc, compiledProject, () -> {
                Dialogue.Dialog.start("Start");          // → presentLine(おう: ゆうしゃよ)
                Dialogue.Dialog.submitAdvance();         // → presentLine(まおうを)
                Dialogue.Dialog.submitAdvance();         // → presentOptions
                Dialogue.Dialog.submitSelect(1);         // → presentLine(なさけないやつめ)
                Dialogue.Dialog.submitAdvance()           // → 再帰 → presentLine(ゆうしゃよ 2 度目)
            })
        };
        // 5 イベント目（index=4）が 1 度目と同じ「ゆうしゃよ…」になっているか
        let firstAndFifth = (List.nth(0, events), List.nth(4, events));
        let expectedLine: ViewEvent = PresentedLine("おう: ゆうしゃよ、よくぞ もどった！");
        let expected: (Option[ViewEvent], Option[ViewEvent]) =
            (Some(expectedLine), Some(expectedLine));
        Assert.assertEq(expected = expected, firstAndFifth)
}
