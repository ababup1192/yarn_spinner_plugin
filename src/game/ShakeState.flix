/// `<<shake <sec>>>` 命令で発火する画面ゆれの残り時間／強度を保持する region 内 Ref。
///
/// 設計意図:
///   - 状態は Ref に閉じる（`Game.start` の region rc に確保し、gameLoop に引き回す）
///   - Yarn 側は同期コマンドとして「セット → submitCommandDone」だけ。
///     実際の表示効果は毎フレームの `tickAndApply` が WorldScene のレイヤ位置に
///     ランダムオフセットを書き込んで実現する
///   - 期限切れ時はオフセットを (0, 0) に戻して終了
mod Game.ShakeState {
    use Duration.Duration

    /// shake の現在状態。`remaining` が 0 でない間アクティブ。
    /// `intensity` は最大オフセット（design px）。
    pub type alias Snapshot = { remaining = Duration, intensity = Float64 }

    /// `Snapshot` を region に保持する Ref。
    pub type alias State[r: Region] = Ref[Snapshot, r]

    /// アクティブでない初期状態を作る。
    pub def empty(rc: Region[r]): State[r] \ r =
        Ref.fresh(rc, ({remaining = Duration.zero(), intensity = 0.0}: Snapshot))

    /// 新しい shake を開始する。既存の shake は上書き（より強い揺れに置き換え）。
    /// `intensity` は最大オフセットの絶対値（design px 単位、典型値は 2〜6 px）。
    pub def start(duration: Duration, intensity: Float64,
                    state: State[r]): Unit \ r =
        Ref.put(({remaining = duration, intensity = intensity}: Snapshot), state)

    /// 現在 shake 中なら true。
    pub def isActive(state: State[r]): Bool \ r =
        not Duration.isExpired(Ref.get(state)#remaining)

    /// 1 フレーム進める：
    ///   - アクティブなら remaining を delta だけ減らし、ランダムオフセットを WorldScene に注入
    ///   - 期限切れになったタイミングでオフセットを (0, 0) にリセット
    ///   - 元から非アクティブなら何もしない（毎フレーム no-op オフセット書き込みは避ける）
    pub def tickAndApply(delta: Duration, state: State[r],
                          scene: Scene[NodeTag]):
                          Scene[NodeTag] \ {Math.Random, r} =
        let current = Ref.get(state);
        if (Duration.isExpired(current#remaining)) scene
        else {
            let nextRemaining = Duration.subClampedToZero(current#remaining, delta);
            Ref.put(({remaining = nextRemaining, intensity = current#intensity}: Snapshot), state);
            if (Duration.isExpired(nextRemaining)) {
                // 期限切れ: オフセットを (0, 0) に戻して終了
                WorldScene.setShakeOffset({x = 0.0, y = 0.0}, scene)
            } else {
                // ランダムに ±intensity の範囲でオフセット
                let dx = RandomUtil.randomRange(-current#intensity, current#intensity);
                let dy = RandomUtil.randomRange(-current#intensity, current#intensity);
                WorldScene.setShakeOffset({x = dx, y = dy}, scene)
            }
        }
}
