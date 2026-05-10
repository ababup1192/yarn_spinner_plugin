/// `Dialogue.Runner.withRunner` が `Dialogue.Test.withTestDialog` の中で
/// 正しく動くことを確認するテスト。
///
/// 純粋層の VM 動作は `TestYarnScenario` で保証済み。ここでは「effect 層が
/// それを下流に正しく仲介すること」だけを検証する。
mod TestDialogueRunner {
    use Dialogue.ViewEvent
    use Dialogue.ViewEvent.{Line, Choices, Command, Complete}

    // fixture は `TestYarnFixture.loadProject()` 経由でインライン取得する。

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
            let (_, log) = Dialogue.Test.withTestDialog(rc, compiledProject, () -> {
                Dialogue.Session.start("Start");          // → presentLine(おう: ゆうしゃよ…)
                Dialogue.Session.submitNext();         // → presentLine(まおうを…)
                Dialogue.Session.submitNext();         // → presentChoices([はい, いいえ])
                Dialogue.Session.submitSelect(0);         // → presentLine(たのもしいぞ)
                Dialogue.Session.submitNext();         // → presentLine(HPは 0 ある)
                Dialogue.Session.submitNext();         // → runCommand("wait 0.5") → 自動完了
                                                          //   → presentLine(たびだちじゃ)
                Dialogue.Session.submitNext()           // → dialogueComplete
            });
            log
        };
        let speaker = Some("おう");
        let expected: List[ViewEvent] =
            Line("おう: ゆうしゃよ、よくぞ もどった！", speaker) ::
            Line("おう: まおうを たおすのじゃ。", speaker) ::
            Choices("はい" :: "いいえ" :: Nil) ::
            Line("おう: たのもしいぞ。", speaker) ::
            Line("おう: ＨＰは 0 ある。 きをつけてゆけ！", speaker) ::
            Command("wait 0.5") ::
            Line("おう: …では、たびだちじゃ。", speaker) ::
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
            let (_, log) = Dialogue.Test.withTestDialog(rc, compiledProject, () -> {
                Dialogue.Session.start("Start");          // → presentLine(おう: ゆうしゃよ)
                Dialogue.Session.submitNext();         // → presentLine(まおうを)
                Dialogue.Session.submitNext();         // → presentChoices
                Dialogue.Session.submitSelect(1);         // → presentLine(なさけないやつめ)
                Dialogue.Session.submitNext()           // → 再帰 → presentLine(ゆうしゃよ 2 度目)
            });
            log
        };
        // 5 イベント目（index=4）が 1 度目と同じ「ゆうしゃよ…」になっているか
        let firstAndFifth = (List.nth(0, events), List.nth(4, events));
        let expectedLine: ViewEvent =
            Line("おう: ゆうしゃよ、よくぞ もどった！", Some("おう"));
        let expected: (Option[ViewEvent], Option[ViewEvent]) =
            (Some(expectedLine), Some(expectedLine));
        Assert.assertEq(expected = expected, firstAndFifth)
}
