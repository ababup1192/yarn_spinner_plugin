/// `<<wait <sec>>>` 命令の残り時間を Duration 単位で持つキュー。
///
/// 設計意図:
///   - 状態は `Game.CommandWaitQueue.Access` effect 経由で操作する。
///     実体（region 内 List[Duration] の Ref）は `Game.start` の handler が握る
///   - Yarn VM は 1 つの `WaitingCommand` 状態しか持てないが、設計の素直さを
///     優先して List で複数同時 wait に耐える形にしておく
///   - 時間値は **すべて Duration**（Float64 の裸の秒数を扱わない）
///   - `tick(delta)` は「期限切れになった件数」を返す。呼び出し側は受け取った件数だけ
///     `Session.submitCommandDone` を発火する責務を負う
mod Game.CommandWaitQueue {
    use Duration.Duration

    /// 待機キューの操作。実体は `Game.start` の handler で region 内 Ref に
    /// 閉じ込めて注入する。
    pub eff Access {
        /// `<<wait <sec>>>` の Duration を 1 件積む。
        def enqueue(duration: Duration): Unit

        /// `delta` だけ全要素を減算し、期限切れになった件数を返す。
        /// 呼び出し側はその件数ぶん `Session.submitCommandDone` を発火する。
        def tick(delta: Duration): Int32

        /// キューに積まれている件数。テスト・デバッグ用。
        def size(): Int32
    }

    /// `Editor.withState(rc)` と同じ流儀の handler 注入。
    /// `queueRef` は内部 closure に閉じ込められ、呼び出し側からは見えない。
    pub def withState(rc: Region[r]):
            (Unit -> a \ ef) -> a \ (ef - Access) + r =
        thunk -> {
            let queueRef: Ref[List[Duration], r] = Ref.fresh(rc, emptyList());
            run thunk() with handler Access {
                def enqueue(d, k) = { enqueueRef(d, queueRef); k() }
                def tick(d, k)    = k(tickRef(d, queueRef))
                def size(k)       = k(sizeRef(queueRef))
            }
        }

    /// 空のキュー（`List[Duration]`）。handler 初期化用に純粋値で返す。
    def emptyList(): List[Duration] = Nil

    /// `Ref[List[Duration], r]` に対する `enqueue` ハンドラ実装。
    def enqueueRef(duration: Duration, queue: Ref[List[Duration], r]): Unit \ r =
        Ref.put(duration :: Ref.get(queue), queue)

    /// `Ref[List[Duration], r]` に対する `tick` ハンドラ実装。
    /// 期限切れ件数を返す。
    def tickRef(delta: Duration, queue: Ref[List[Duration], r]): Int32 \ r =
        let advanced = Ref.get(queue)
            |> List.map(remaining -> Duration.subClampedToZero(remaining, delta));
        let (expired, alive) = List.partition(Duration.isExpired, advanced);
        Ref.put(alive, queue);
        List.length(expired)

    /// `Ref[List[Duration], r]` に対する `size` ハンドラ実装。
    def sizeRef(queue: Ref[List[Duration], r]): Int32 \ r =
        List.length(Ref.get(queue))
}
