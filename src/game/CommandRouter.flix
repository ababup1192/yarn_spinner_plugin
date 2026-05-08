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
///   - **シーンを変更するコマンド**（`<<bg>>` / `<<sprite>>`）は `WorldScene` の API を呼んで
///     scene を畳んでいき、最後に外へ返す
///   - **未対応コマンド**は `println` でログを出して即完了。story を止めない
mod Game.CommandRouter {
    use Duration.Duration

    /// `Dialogue.SceneView.CommandInbox` から溜まったコマンドをすべて取り出して dispatch し、
    /// `WaitQueue` を `delta` だけ進めて期限切れ件数ぶん `submitCommandDone` を発火する。
    /// `bg` / `sprite` 系コマンドは `scene` を畳み込んでいくため、最終的な scene を返す。
    pub def processCommands(waitQueue: Game.CommandWaitQueue.WaitQueue[r],
                              delta: {delta = Duration},
                              scene: Scene[NodeTag]):
                              Scene[NodeTag] \ {
                                Dialogue.SceneView.CommandInbox,
                                GameEngine.Audio,
                                Dialogue.Session,
                                Yarn.VariableAccess,
                                IO,
                                r
                              } =
        let pending = Dialogue.SceneView.CommandInbox.takeAllCommands();
        let afterDispatch =
            List.foldLeft((sc, text) -> dispatchOne(text, waitQueue, sc),
                scene, pending);
        let expired = Game.CommandWaitQueue.tick(delta#delta, waitQueue);
        completeMany(expired);
        afterDispatch

    /// 1 件のコマンド文字列を parse → ハンドラに振り分け。
    /// 同期コマンドは即 `submitCommandDone`、非同期（wait）は WaitQueue に積むだけで
    /// 完了通知は呼ばない（後続の `tick` が発火する）。
    /// シーンを変えるコマンドは新しい scene を返し、それ以外は受け取った scene をそのまま返す。
    def dispatchOne(text: String,
                     waitQueue: Game.CommandWaitQueue.WaitQueue[r],
                     scene: Scene[NodeTag]):
                     Scene[NodeTag] \ {
                       GameEngine.Audio, Dialogue.Session, Yarn.VariableAccess, IO, r
                     } =
        let (name, args) = Dialogue.CommandParser.parse(text);
        match (name, args) {
            // 音響: bgm play <name> [loop]
            case ("bgm", "play" :: assetName :: _) =>
                GameEngine.Audio.playAudio(assetName);
                Dialogue.Session.submitCommandDone();
                scene
            // 音響: bgm fade <sec> — フェード未実装なので当面は素通し
            case ("bgm", "fade" :: _) =>
                Dialogue.Session.submitCommandDone();
                scene
            // 音響: se <name>
            case ("se", assetName :: _) =>
                GameEngine.Audio.playAudio(assetName);
                Dialogue.Session.submitCommandDone();
                scene
            // 待機: wait <sec>
            case ("wait", secStr :: _) =>
                match Float64.fromString(secStr) {
                    case Some(seconds) =>
                        Game.CommandWaitQueue.enqueue(
                            Duration.seconds(seconds), waitQueue);
                        scene
                    case None =>
                        println("[CommandRouter] invalid wait seconds: ${secStr}");
                        Dialogue.Session.submitCommandDone();
                        scene
                }
            // フラグ: flag set <name> / flag clear <name>
            case ("flag", "set" :: flagName :: _) =>
                Yarn.VariableAccess.setBool("\$flag_${flagName}", true);
                Dialogue.Session.submitCommandDone();
                scene
            case ("flag", "clear" :: flagName :: _) =>
                Yarn.VariableAccess.setBool("\$flag_${flagName}", false);
                Dialogue.Session.submitCommandDone();
                scene
            // インベントリ: item add <id> / item remove <id>
            case ("item", "add" :: itemId :: _) =>
                Yarn.VariableAccess.setBool("\$inv_${itemId}", true);
                Dialogue.Session.submitCommandDone();
                scene
            case ("item", "remove" :: itemId :: _) =>
                Yarn.VariableAccess.setBool("\$inv_${itemId}", false);
                Dialogue.Session.submitCommandDone();
                scene
            // 背景: bg <name> [fade <sec>] — fade は未実装、即時切替のみ
            case ("bg", bgName :: _) =>
                let next = WorldScene.setBackground(bgName, scene);
                Dialogue.Session.submitCommandDone();
                next
            // キャラ: sprite show <name> [position|variant]
            // 2 引数目（center / open / closed 等）は当面無視。
            case ("sprite", "show" :: spriteName :: _) =>
                let next = WorldScene.showCharacter(spriteName, scene);
                Dialogue.Session.submitCommandDone();
                next
            // キャラ: sprite hide <name>
            case ("sprite", "hide" :: spriteName :: _) =>
                let next = WorldScene.hideCharacter(spriteName, scene);
                Dialogue.Session.submitCommandDone();
                next
            // 空文字（理論上は来ない）
            case ("", _) =>
                Dialogue.Session.submitCommandDone();
                scene
            // 未対応コマンド（phase / save / load / hotspot / shake 等）
            // 次フェーズで実装。当面はログに出して story を進める。
            case _ =>
                println("[CommandRouter] unhandled: ${name} ${args}");
                Dialogue.Session.submitCommandDone();
                scene
        }

    /// `count` 回 `submitCommandDone` を呼ぶ。WaitQueue の期限切れ通知用。
    def completeMany(count: Int32): Unit \ Dialogue.Session =
        if (count <= 0) ()
        else {
            Dialogue.Session.submitCommandDone();
            completeMany(count - 1)
        }
}
