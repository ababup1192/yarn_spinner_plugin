/// `<<wait <sec>>>` 命令の残り時間を Duration 単位で持つ region 内キュー。
///
/// 設計意図:
///   - Yarn VM は 1 つの `WaitingCommand` 状態しか持てないが、設計の素直さを
///     優先して List で複数同時 wait に耐える形にしておく
///   - 時間値は **すべて Duration**（Float64 の裸の秒数を扱わない）
///   - `tick(delta)` は「期限切れになった件数」を返す。呼び出し側は受け取った件数だけ
///     `Session.submitCommandDone` を発火する責務を負う
mod Game.CommandWaitQueue {
    use Duration.Duration

    /// 残り Duration のリストを region に保持する Ref。
    /// 1 エントリ = 1 件の `<<wait>>` 命令。
    pub type alias WaitQueue[r: Region] = Ref[List[Duration], r]

    /// 空のキューを生成する。
    pub def empty(rc: Region[r]): WaitQueue[r] \ r =
        Ref.fresh(rc, Nil)

    /// 新しい待機時間をキューに積む。`<<wait 0.5>>` のハンドラから呼ばれる。
    pub def enqueue(duration: Duration, queue: WaitQueue[r]): Unit \ r =
        Ref.put(duration :: Ref.get(queue), queue)

    /// `delta` だけ全要素を減算し、`isExpired` になった要素をキューから取り除く。
    /// 取り除いた件数を返す — 呼び出し側はその数だけ `Session.submitCommandDone` を呼ぶ。
    pub def tick(delta: Duration, queue: WaitQueue[r]): Int32 \ r =
        let advanced = Ref.get(queue)
            |> List.map(remaining -> Duration.subClampedToZero(remaining, delta));
        let (expired, alive) = List.partition(Duration.isExpired, advanced);
        Ref.put(alive, queue);
        List.length(expired)

    /// キューに積まれている件数。デバッグ・テスト用。
    pub def size(queue: WaitQueue[r]): Int32 \ r =
        List.length(Ref.get(queue))
}
