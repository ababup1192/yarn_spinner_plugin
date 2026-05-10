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

    /// `<<shake <sec>>>` の最大オフセット（design px）。design 320×240 に対して
    /// 4px ぶれる程度が「ガクッ」と感じる範囲。引数で可変にしたくなったら 2 引数目を
    /// パースする形に拡張する。
    def shakeIntensity(): Float64 = 4.0

    /// `Dialogue.SceneView.CommandInbox` から溜まったコマンドをすべて取り出して dispatch し、
    /// `WaitQueue` を `delta` だけ進めて期限切れ件数ぶん `submitCommandDone` を発火する。
    /// `bg` / `sprite` 系コマンドは `scene` を畳み込んでいくため、最終的な scene を返す。
    /// 状態（wait queue / shake / audio fader）は custom effect 経由で参照する。
    /// 実体は `Game.start` で region 内 Ref に閉じ込めて handler 注入される。
    pub def processCommands(delta: {delta = Duration},
                              scene: Scene[NodeTag]):
                              Scene[NodeTag] \ {
                                Dialogue.SceneView.CommandInbox,
                                GameEngine.Audio,
                                Dialogue.Session,
                                Yarn.VariableAccess,
                                Game.CommandWaitQueue.Access,
                                Game.ShakeState.Access,
                                Game.AudioFader.Access,
                                Game.RoomState.Access,
                                Game.Inventory.Access,
                                Fs.FileRead,
                                Fs.FileWrite,
                                IO
                              } =
        let pending = Dialogue.SceneView.CommandInbox.takeAllCommands();
        let afterDispatch =
            List.foldLeft((sc, text) -> dispatchOne(text, sc), scene, pending);
        let expired = Game.CommandWaitQueue.Access.tick(delta#delta);
        completeMany(expired);
        afterDispatch

    /// 1 件のコマンド文字列を parse → ハンドラに振り分け。
    /// 同期コマンドは即 `submitCommandDone`、非同期（wait）は WaitQueue に積むだけで
    /// 完了通知は呼ばない（後続の `tick` が発火する）。
    /// シーンを変えるコマンドは新しい scene を返し、それ以外は受け取った scene をそのまま返す。
    def dispatchOne(text: String, scene: Scene[NodeTag]):
                     Scene[NodeTag] \ {
                       GameEngine.Audio, Dialogue.Session, Yarn.VariableAccess,
                       Game.CommandWaitQueue.Access, Game.ShakeState.Access,
                       Game.AudioFader.Access, Game.RoomState.Access,
                       Game.Inventory.Access,
                       Fs.FileRead, Fs.FileWrite, IO
                     } =
        let (name, args) = Dialogue.CommandParser.parse(text);
        match (name, args) {
            // 音響: bgm play <name> [loop]
            // AudioFader に名前を登録して音量を 1.0 にリセット（前回の fade-out で
            // gain が 0 のまま残るのを防ぐ）。`alSourcePlay` 自体は playAudio で発火。
            case ("bgm", "play" :: assetName :: _) =>
                Game.AudioFader.setBgm(assetName);
                GameEngine.Audio.playAudio(assetName);
                Dialogue.Session.submitCommandDone();
                scene
            // 音響: bgm fade <sec>
            // 現在 BGM の音量を 1.0 → 0.0 にフェード。AudioFader が毎フレーム
            // setVolume を発火し、完了時に stopAudio する。
            case ("bgm", "fade" :: secStr :: _) =>
                match Float64.fromString(secStr) {
                    case Some(seconds) =>
                        Game.AudioFader.fadeOutCurrent(Duration.seconds(seconds))
                    case None =>
                        println("[CommandRouter] invalid bgm fade seconds: ${secStr}")
                };
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
                        Game.CommandWaitQueue.Access.enqueue(Duration.seconds(seconds));
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
            // インベントリ: inv add <id> / inv remove <id>
            // `Game.Inventory.Access` を SoT として更新する。`inv_has(id)` ビルトインは
            // Game.YarnBuiltinExtension が同じ Access から読むので一貫する。
            case ("inv", "add" :: itemId :: _) =>
                Game.Inventory.Access.add(itemId);
                Dialogue.Session.submitCommandDone();
                scene
            case ("inv", "remove" :: itemId :: _) =>
                Game.Inventory.Access.remove(itemId);
                Dialogue.Session.submitCommandDone();
                scene
            // 背景: bg <name> [fade <sec>] — fade は未実装、即時切替のみ
            case ("bg", bgName :: _) =>
                let next = WorldScene.setBackground(bgName, scene);
                Dialogue.Session.submitCommandDone();
                next
            // 部屋遷移: room enter <id>
            // RoomState の roomId とホットスポット状態テーブルを `RoomCatalog` の
            // 初期値で再構築し、RoomScene の背景 Sprite + ホットスポット ColorRect も
            // 差し替える。catalog に無い id でも `RoomScene.enter` 側で「空っぽ部屋」に
            // 整合するので、yarn 側でクラッシュさせない。
            case ("room", "enter" :: roomId :: _) =>
                let initialHs = Game.RoomCatalog.initialHotspots(roomId);
                Game.RoomState.Access.enter(roomId, initialHs);
                let next = RoomScene.enter(roomId, scene);
                Dialogue.Session.submitCommandDone();
                next
            // ホットスポット状態操作: hotspot {lock|unlock|show|hide} <id>
            // 詳細は `dispatchHotspot` に委譲（dispatchOne の JVM メソッドサイズ制限対策）。
            case ("hotspot", action :: hotspotId :: _) =>
                dispatchHotspot(action, hotspotId);
                scene
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
            // 画面ゆれ: shake <sec> — 強度は固定（design 単位 4px ぶん）。
            // ShakeState に積むだけで毎フレームの tickAndApply が描画に反映する。
            case ("shake", secStr :: _) =>
                match Float64.fromString(secStr) {
                    case Some(seconds) =>
                        Game.ShakeState.start(Duration.seconds(seconds), shakeIntensity())
                    case None =>
                        println("[CommandRouter] invalid shake seconds: ${secStr}")
                };
                Dialogue.Session.submitCommandDone();
                scene
            // フェーズ遷移: phase <nodeName>
            // 旧 VM を破棄して `nodeName` から新規 Session を始める高レベル切替。
            // story.yarn の GameOver 末尾で `<<phase Start>>` → `<<stop>>` の組で
            // 「死亡 → タイトルに戻る」を表現するために使う。
            // `Session.start` が新しい VM を vmRef に差し替えるので、後続の `<<stop>>`
            // 命令は旧 VM 上のもので決して実行されない（旧 VM はそのまま GC される）。
            // submitCommandDone は呼ばない: 新 VM はもう自分の最初の命令まで進んでおり、
            // 旧 VM の WaitingCommand に対する完了通知は意味を持たない。
            case ("phase", phaseName :: _) =>
                Dialogue.Session.start(phaseName);
                scene
            // セーブ: save <slot>
            // 現在ノード名と全変数を `saves/slot{N}.json` に書き出す。
            // ロジックは `attemptSave` に切り出し、ここはログ出力と
            // submitCommandDone の発火だけ。
            case ("save", slotStr :: _) =>
                match attemptSave(slotStr) {
                    case Ok(_)    => ()
                    case Err(msg) => println("[CommandRouter] ${msg}")
                };
                Dialogue.Session.submitCommandDone();
                scene
            // ロード: load <slot>
            // 成功時: `Session.restart` で新 VM を建てて旧 VM を破棄。submitCommandDone
            // は呼ばない（phase Start と同じ理屈）。
            // 失敗時: ログ + `$_load_failed = true` + submitCommandDone で旧 VM を
            // 進める。story 側がこれを見て「セーブデータがありません」分岐を出せる。
            case ("load", slotStr :: _) =>
                match attemptLoad(slotStr) {
                    case Ok(data) =>
                        Dialogue.Session.restart(
                            Game.SaveData.nodeName(data),
                            Game.SaveData.variables(data))
                    case Err(msg) =>
                        println("[CommandRouter] ${msg}");
                        Yarn.VariableAccess.setBool("\$_load_failed", true);
                        Dialogue.Session.submitCommandDone()
                };
                scene
            // 空文字（理論上は来ない）
            case ("", _) =>
                Dialogue.Session.submitCommandDone();
                scene
            // 未対応コマンド（hotspot / 他）
            // 当面はログに出して story を進める。
            case _ =>
                println("[CommandRouter] unhandled: ${name} ${args}");
                Dialogue.Session.submitCommandDone();
                scene
        }

    /// `<<hotspot {lock|unlock|show|hide} <id>>>` を RoomState に反映する。
    /// 共通の `submitCommandDone` 発火もこの中で行う（呼び出し側は scene を返すだけ）。
    /// 不明な action はログに出して完了通知を返す（story を止めない）。
    def dispatchHotspot(action: String, hotspotId: String):
            Unit \ {Dialogue.Session, Game.RoomState.Access, IO} =
        match action {
            case "unlock" => Game.RoomState.Access.setLocked(hotspotId, false)
            case "lock"   => Game.RoomState.Access.setLocked(hotspotId, true)
            case "show"   => Game.RoomState.Access.setVisible(hotspotId, true)
            case "hide"   => Game.RoomState.Access.setVisible(hotspotId, false)
            case other    => println("[CommandRouter] unknown hotspot action: ${other}")
        };
        Dialogue.Session.submitCommandDone()

    /// `count` 回 `submitCommandDone` を呼ぶ。WaitQueue の期限切れ通知用。
    def completeMany(count: Int32): Unit \ Dialogue.Session =
        if (count <= 0) ()
        else {
            Dialogue.Session.submitCommandDone();
            completeMany(count - 1)
        }

    /// `<<save N>>` のロジック。失敗時はログ用の文字列を `Err` に詰める。
    /// 各段の `Option` / `Result` を `forM` で 1 列に並べ、ネスト無しで失敗を
    /// 短絡させる。dispatchOne 側はこの結果を pretty-print するだけ。
    def attemptSave(slotStr: String):
            Result[String, Unit] \ {Yarn.VariableAccess, Fs.FileWrite} =
        forM (
            slot <- Int32.fromString(slotStr)
                      |> Option.toOk("invalid save slot: ${slotStr}");
            node <- Yarn.VariableAccess.currentNode()
                      |> Option.toOk("save: VM not active, skipped");
            _    <- {
                let vars = Yarn.VariableAccess.variableSnapshot();
                let data = Game.SaveData.SaveData.SaveData(node, vars);
                SaveManager.write(slot, data)
                    |> Result.mapErr(error -> "save write failed: ${error}")
            }
        ) yield ()

    /// `<<load N>>` のロジック。成功で `SaveData` を返し、dispatchOne 側で
    /// `Session.restart` に流す。失敗時はログ文字列を返す。
    def attemptLoad(slotStr: String):
            Result[String, Game.SaveData.SaveData] \ Fs.FileRead =
        forM (
            slot <- Int32.fromString(slotStr)
                      |> Option.toOk("invalid load slot: ${slotStr}");
            data <- SaveManager.read(slot)
                      |> Option.toOk("load: no save in slot ${slotStr}")
        ) yield data
}
