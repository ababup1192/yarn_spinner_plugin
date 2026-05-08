/// Yarn の `<<command>>` 文字列を実処理に振り分ける gameLoop 段。
///
/// `Dialogue.SceneView.CommandInbox` に溜まったコマンド文字列をフレーム毎にすべて取り出し、
/// `Dialogue.CommandParser.parse` で `(name, args)` に分解して、コマンド名に応じた
/// 副作用（音再生・変数書き込み・待機キュー登録 等）を発火する。
///
/// 設計の要点:
///   - **同期コマンド**（音・フラグ・アイテム）は処理直後に `Dialogue.Session.submitCommandDone`
///     を呼んで Yarn VM を進める
///   - **非同期コマンド**（`<<wait>>`）は `Game.CommandWaitQueue` に Duration を積む。
///     毎フレーム末尾の `tick` で期限切れになったぶんだけ `submitCommandDone` を発火する
///   - **未対応コマンド**は `println` でログを出して即完了。story を止めない
///   - Scene には触らない。配線通過のみ
mod Game.CommandRouter {
    use Duration.Duration

    /// `Dialogue.SceneView.CommandInbox` から溜まったコマンドをすべて取り出して dispatch し、
    /// `WaitQueue` を `delta` だけ進めて期限切れ件数ぶん `submitCommandDone` を発火する。
    /// `scene` はそのまま返す（このモジュールはシーンを変えない）。
    pub def processCommands(waitQueue: Game.CommandWaitQueue.WaitQueue[r],
                              delta: {delta = Duration},
                              scene: Scene[s]):
                              Scene[s] \ {
                                Dialogue.SceneView.CommandInbox,
                                GameEngine.Audio,
                                Dialogue.Session,
                                Yarn.VariableAccess,
                                IO,
                                r
                              } =
        let pending = Dialogue.SceneView.CommandInbox.takeAllCommands();
        List.forEach(text -> dispatchOne(text, waitQueue), pending);
        let expired = Game.CommandWaitQueue.tick(delta#delta, waitQueue);
        completeMany(expired);
        scene

    /// 1 件のコマンド文字列を parse → ハンドラに振り分け。
    /// 同期コマンドは即 `submitCommandDone`、非同期（wait）は WaitQueue に積むだけで
    /// 完了通知は呼ばない（後続の `tick` が発火する）。
    def dispatchOne(text: String,
                     waitQueue: Game.CommandWaitQueue.WaitQueue[r]):
                     Unit \ {
                       GameEngine.Audio, Dialogue.Session, Yarn.VariableAccess, IO, r
                     } =
        let (name, args) = Dialogue.CommandParser.parse(text);
        match (name, args) {
            // 音響: bgm play <name> [loop]
            case ("bgm", "play" :: assetName :: _) =>
                GameEngine.Audio.playAudio(assetName);
                Dialogue.Session.submitCommandDone()
            // 音響: bgm fade <sec> — フェード未実装なので当面は素通し
            case ("bgm", "fade" :: _) =>
                Dialogue.Session.submitCommandDone()
            // 音響: se <name>
            case ("se", assetName :: _) =>
                GameEngine.Audio.playAudio(assetName);
                Dialogue.Session.submitCommandDone()
            // 待機: wait <sec>
            case ("wait", secStr :: _) =>
                match Float64.fromString(secStr) {
                    case Some(seconds) =>
                        Game.CommandWaitQueue.enqueue(
                            Duration.seconds(seconds), waitQueue)
                    case None => {
                        println("[CommandRouter] invalid wait seconds: ${secStr}");
                        Dialogue.Session.submitCommandDone()
                    }
                }
            // フラグ: flag set <name> / flag clear <name>
            case ("flag", "set" :: flagName :: _) =>
                Yarn.VariableAccess.setBool("\$flag_${flagName}", true);
                Dialogue.Session.submitCommandDone()
            case ("flag", "clear" :: flagName :: _) =>
                Yarn.VariableAccess.setBool("\$flag_${flagName}", false);
                Dialogue.Session.submitCommandDone()
            // インベントリ: item add <id> / item remove <id>
            case ("item", "add" :: itemId :: _) =>
                Yarn.VariableAccess.setBool("\$inv_${itemId}", true);
                Dialogue.Session.submitCommandDone()
            case ("item", "remove" :: itemId :: _) =>
                Yarn.VariableAccess.setBool("\$inv_${itemId}", false);
                Dialogue.Session.submitCommandDone()
            // 空文字（理論上は来ない）
            case ("", _) =>
                Dialogue.Session.submitCommandDone()
            // 未対応コマンド（bg / sprite / phase / save / load / hotspot / shake 等）
            // 次フェーズで実装。当面はログに出して story を進める。
            case _ => {
                println("[CommandRouter] unhandled: ${name} ${args}");
                Dialogue.Session.submitCommandDone()
            }
        }

    /// `count` 回 `submitCommandDone` を呼ぶ。WaitQueue の期限切れ通知用。
    def completeMany(count: Int32): Unit \ Dialogue.Session =
        if (count <= 0) ()
        else {
            Dialogue.Session.submitCommandDone();
            completeMany(count - 1)
        }
}
