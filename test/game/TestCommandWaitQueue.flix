/// `Game.CommandWaitQueue` の単体テスト。
///
/// Duration ベースの「N 件の待機タイマーを積み、毎フレーム delta 引いて期限切れを取り除く」
/// 振る舞いを 3 ケースで確認する。
mod TestCommandWaitQueue {
    use Duration.Duration

    /// `<<wait 0.5>>` 1 件を積み、ちょうど 0.5 秒経過で 1 件期限切れになる。
    /// 残量も 0 件になっていることを 1 つのタプルで確認する。
    @Test
    def testEnqueueExpiresExactlyAtDuration(): Unit \ Assert =
        region rc {
            let queue = Game.CommandWaitQueue.empty(rc);
            Game.CommandWaitQueue.enqueue(Duration.seconds(0.5), queue);
            let expired = Game.CommandWaitQueue.tick(Duration.seconds(0.5), queue);
            let remaining = Game.CommandWaitQueue.size(queue);
            Assert.assertEq(expected = (1, 0), (expired, remaining))
        }

    /// 部分的な経過（0.3 < 1.0）では期限切れ 0 件、キューには 1 件残る。
    @Test
    def testTickPartialKeepsEntryAlive(): Unit \ Assert =
        region rc {
            let queue = Game.CommandWaitQueue.empty(rc);
            Game.CommandWaitQueue.enqueue(Duration.seconds(1.0), queue);
            let expired = Game.CommandWaitQueue.tick(Duration.seconds(0.3), queue);
            let remaining = Game.CommandWaitQueue.size(queue);
            Assert.assertEq(expected = (0, 1), (expired, remaining))
        }

    /// 異なる Duration を 2 件積んで段階的に tick する。
    /// タイムライン:
    ///   t=0.0  enqueue 0.2, enqueue 0.5  (queue: [0.2, 0.5])
    ///   t=0.3  tick 0.3  → 0.2 は -0.1 → expired、0.5 → 0.2
    ///                     expired 件数 = 1、残り = 1
    ///   t=0.5  tick 0.2  → 0.2 → 0.0 → expired
    ///                     expired 件数 = 1、残り = 0
    @Test
    def testTickExpiresIndependently(): Unit \ Assert =
        region rc {
            let queue = Game.CommandWaitQueue.empty(rc);
            Game.CommandWaitQueue.enqueue(Duration.seconds(0.2), queue);
            Game.CommandWaitQueue.enqueue(Duration.seconds(0.5), queue);
            let firstExpired  = Game.CommandWaitQueue.tick(Duration.seconds(0.3), queue);
            let afterFirst    = Game.CommandWaitQueue.size(queue);
            let secondExpired = Game.CommandWaitQueue.tick(Duration.seconds(0.2), queue);
            let afterSecond   = Game.CommandWaitQueue.size(queue);
            Assert.assertEq(
                expected = (1, 1, 1, 0),
                (firstExpired, afterFirst, secondExpired, afterSecond))
        }
}
