/// `<<bgm play <name>>>` で再生中の BGM 名と、`<<bgm fade <sec>>>` で進行中の
/// 音量フェードを保持する region 内 Ref。
///
/// 設計意図:
///   - BGM は同時に 1 つだけ流れる前提（story.yarn の用例どおり）。`currentBgm`
///     が現在鳴っている論理名を保持する
///   - フェードは進行中のものが 1 つだけ。`fade` が `Some` のときに `tick` が
///     毎フレーム音量を補間して `setVolume` を発火する
///   - フェード完了で `stopAudio` を呼んで音を止め、`fade = None` に戻す
///   - `bgm play` は新しい音を流す際にフェードをキャンセルし、音量を 1.0 に
///     リセットする（前回の fade-out で 0 になった gain が残るのを防ぐ）
mod Game.AudioFader {
    use Duration.Duration

    /// 進行中フェード 1 件の状態。`elapsed` を `delta` ずつ進めて、
    /// `t = elapsed / duration` で `startVolume` → `endVolume` を線形補間する。
    pub type alias FadeProgress = {
        soundName = String,
        startVolume = Float32,
        endVolume = Float32,
        elapsed = Duration,
        duration = Duration
    }

    /// 現在の BGM 名と、進行中フェード（あれば）。
    pub type alias Snapshot = {
        currentBgm = Option[String],
        fade = Option[FadeProgress]
    }

    /// 状態を保持する region 内 Ref。
    pub type alias State[r: Region] = Ref[Snapshot, r]

    /// BGM 未再生・フェードなしの初期状態を作る。
    pub def empty(rc: Region[r]): State[r] \ r =
        Ref.fresh(rc, ({currentBgm = None, fade = None}: Snapshot))

    /// `bgm play <name>` から呼び出す。
    /// 別 BGM が鳴っていれば停止し、進行中フェードをキャンセル、currentBgm を上書き、
    /// 新しい BGM の音量を 1.0 にリセットする。
    /// 実際の `playAudio` 呼び出し（先頭から再生）は呼び出し側 (CommandRouter) の責務。
    /// ※ 同名 BGM の再指定の場合は stopAudio を呼ばない（CommandRouter 側で
    ///   playAudio が alSourceStop+Play して頭出しするので二度手間）
    pub def setBgm(name: String, state: State[r]):
                    Unit \ {GameEngine.Audio, r} =
        let current = Ref.get(state);
        match current#currentBgm {
            case Some(prev) if prev != name => GameEngine.Audio.stopAudio(prev)
            case _                          => ()
        };
        Ref.put(({currentBgm = Some(name), fade = None}: Snapshot), state);
        GameEngine.Audio.setVolume(name, 1.0f32)

    /// `bgm fade <sec>` から呼び出す。currentBgm を 1.0 → 0.0 にフェードする。
    /// currentBgm が無ければ no-op（鳴っていない BGM はフェードのしようがない）。
    pub def fadeOutCurrent(duration: Duration, state: State[r]): Unit \ r =
        let current = Ref.get(state);
        match current#currentBgm {
            case None => ()
            case Some(name) =>
                let progress: FadeProgress = {
                    soundName = name,
                    startVolume = 1.0f32,
                    endVolume = 0.0f32,
                    elapsed = Duration.zero(),
                    duration = duration
                };
                Ref.put(({fade = Some(progress) | current}: Snapshot), state)
        }

    /// 1 フレーム進める：
    ///   - `fade = None` なら no-op
    ///   - 進行中なら elapsed を delta ぶん進めて、線形補間した音量を `setVolume`
    ///   - 完了タイミングで `stopAudio` を発火し、`fade = None` に戻す
    ///   - 完了時は `currentBgm` も `None` にする（フェードアウトしきった音は
    ///     「鳴っていない」扱い：次に `bgm play` が来るまで何も流さない）
    pub def tick(delta: Duration, state: State[r]): Unit \ {GameEngine.Audio, r} =
        let current = Ref.get(state);
        match current#fade {
            case None => ()
            case Some(progress) =>
                let nextElapsed = Duration.add(progress#elapsed, delta);
                let t = Duration.ratio(nextElapsed, progress#duration);
                if (t >= 1.0) {
                    GameEngine.Audio.setVolume(progress#soundName, progress#endVolume);
                    GameEngine.Audio.stopAudio(progress#soundName);
                    Ref.put(({currentBgm = None, fade = None}: Snapshot), state)
                } else {
                    let s = Float32.toFloat64(progress#startVolume);
                    let e = Float32.toFloat64(progress#endVolume);
                    let v = s + (e - s) * t;
                    let v32 = Float64.tryToFloat32(v)
                        |> Option.getWithDefault(progress#endVolume);
                    GameEngine.Audio.setVolume(progress#soundName, v32);
                    let updatedProgress = {elapsed = nextElapsed | progress};
                    Ref.put(({fade = Some(updatedProgress) | current}: Snapshot), state)
                }
        }
}
