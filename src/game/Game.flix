/// ゲーム本体エントリ。`yarn/output.json` を読み込み、`DialogueScene` レイヤを
/// 1 枚積んで対話デモを駆動する。
///
/// engine-guide / scene-editor / game-loop の各規約に揃えた構成：
///   - `NodeTag.Dialogue(DialogueScene.Data)` でレイヤ状態を NodeTag に内包
///   - `InputHandler[NodeTag]` は `DialogueScene.input` に委譲するだけ（dispatch のみ）
///   - `mod Game` は配線役。シーン構築・ロジックは XxxScene 側
///   - `gameLoop` は 7 段パイプライン:
///       F1 トグル → エディタ ON 判定 → ゲーム更新 → ホットリロード判定
///       → エディタオーバーレイ → 描画 → 末尾再帰

/// Scene[s] のジェネリック s に当てるタグ。
/// 対話レイヤだけがゲームロジックを持つ（root の `Dialogue.UIState` に状態を集約）。
pub enum NodeTag {
    case NoTag
    case Dialogue(Dialogue.UIState)
}

/// Node 実装。Dialogue レイヤの `process` を `DialogueScene.process` に委譲する。
/// `process` 内で auto-next が `Session.submitNext` を、新行検知が
/// `GameEngine.Audio.playAudio` を発火するため Aef は 3 つ必要。
instance Node[NodeTag] {
    type Aef = { Dialogue.SceneView.Inbox, Dialogue.Session, GameEngine.Audio }

    redef process(delta: Duration.Duration, node: EngineNode[NodeTag],
                   _path: NodePath, scene: Scene[NodeTag]):
                    (EngineNode[NodeTag], Scene[NodeTag])
                    \ {Dialogue.SceneView.Inbox, Dialogue.Session, GameEngine.Audio} =
        match node {
            case EngineNode.CanvasLayerWithState(layer, NodeTag.Dialogue(state)) =>
                DialogueScene.process(delta, layer, state, scene)
            case _ => (node, scene)
        }
}

/// 入力ハンドラ。確定キーで tap SE を鳴らすため `GameEngine.Audio` も Aef に含める。
instance InputEvent.InputHandler[NodeTag] {
    type Aef = { Dialogue.Session, GameEngine.Audio }

    redef onKeyPressed(key: GameEngine.Key, scene: Scene[NodeTag]):
                        Scene[NodeTag] \ { Dialogue.Session, GameEngine.Audio } =
        DialogueScene.input(key, scene)
}

mod Game {
    use Yarn.Types.YarnProject

    // ════════════════════════════════════════════════════════════════════════
    // 解像度
    // ════════════════════════════════════════════════════════════════════════

    /// デザイン解像度（ロジック側の基準）。
    pub def designWi(): Int32 = 320
    pub def designHi(): Int32 = 240

    /// 初期ウィンドウサイズ（OS ピクセル）。
    pub def windowWi(): Int32 = 960
    pub def windowHi(): Int32 = 720

    // ════════════════════════════════════════════════════════════════════════
    // fixture 読み込み
    // ════════════════════════════════════════════════════════════════════════

    /// `yarn/output.json` を読み込み `YarnProject` を返す。失敗は `bug!`。
    /// ファイルシステム依存はここに局所化される（本番経路はディスクから読む）。
    /// 読み込み API は `Fs.ReadFile.read` + `Fs.ReadFile.runWithFileRead` で
    /// `Fs.FileRead` 効果に変換する（プロジェクトの SceneLoader と同じパターン）。
    def loadProject(): YarnProject \ Fs.FileRead =
        let readResult = run {
            Fs.ReadFile.read("yarn/output.json")
        } with Fs.ReadFile.runWithFileRead;
        let jsonText = readResult |> Result.getWithDefault("");
        match Yarn.Loader.parseProject(jsonText) {
            case Ok(loaded)  => loaded
            case Err(error)  => bug!("yarn/output.json parse failed: ${error}")
        }

    // ════════════════════════════════════════════════════════════════════════
    // シーン構築
    // ════════════════════════════════════════════════════════════════════════

    /// 対話レイヤを 1 枚積んだ初期シーンを構築する。
    /// `addDialogueLayer` 自身が `DialogueScene.scene.json` を読みに行くので Fs.FileRead が必要。
    /// `fontAtlas` / `boldFontAtlas` は `start` で事前取得して渡す
    /// （ホットリロード時の再構築でも再利用）。bold は `[b]...[/b]` 用。
    def buildScene(fontAtlas: FontAtlas, boldFontAtlas: FontAtlas):
                    Scene[NodeTag] \ {GameEngine.Game, Fs.FileRead} =
        Scene.empty()
            |> WorldScene.addWorldLayers
            |> DialogueScene.addDialogueLayer(fontAtlas, boldFontAtlas)

    // ════════════════════════════════════════════════════════════════════════
    // start / gameLoop
    // ════════════════════════════════════════════════════════════════════════

    /// ゲーム起動エントリ。`$hp` 等の変数初期値は yarn の `<<declare>>` に従う。
    ///
    /// 対話関連の handler 連結（Runner / AsyncOnly / SceneView+Inbox+CommandInbox）は
    /// `Dialogue.withDialog` に閉じ込めてあり、region / event queue は外には漏れない。
    /// `Editor.withState(rc)` で F1 トグル + ホットリロード監視 + EditHistory(undo) を注入する。
    /// `<<wait>>` 用の WaitQueue も region rc に確保し、毎フレームの gameLoop に渡す。
    pub def start():
            Unit \ {GameEngine.Game, GameEngine.Audio, Fs.FileRead, Fs.FileWrite,
                    Fs.Glob, Fs.ModificationTime, IO, Chan, NonDet} =
        // 注意: Flix では `project` は予約語のため変数名に使えない。
        let yarnProject = loadProject();
        let fontAtlas = GameEngine.Game.getFontAtlas(DialogueScene.fontName());
        let boldFontAtlas = GameEngine.Game.getFontAtlas(DialogueScene.boldFontName());
        region rc {
            let waitQueue = Game.CommandWaitQueue.empty(rc);
            run {
                Dialogue.Session.start("Start");
                gameLoop(fontAtlas, boldFontAtlas, waitQueue, buildScene(fontAtlas, boldFontAtlas))
            } with Editor.withState(rc)
              with Dialogue.withDialog(yarnProject)
        }

    /// メインループ（7 段パイプライン）。
    ///   (1) F1 トグル + マウス選択 / ドラッグ / リサイズ / 矢印 nudge / Cmd+Z（エディタ入力を最優先）
    ///   (2) エディタ ON ならゲーム更新スキップ
    ///   (3) Yarn コマンド処理（音再生・wait カウントダウン・フラグ書き込み）
    ///   (4) ホットリロード判定（scene.json 変更 → 全再構築）
    ///   (5) エディタオーバーレイ → 描画
    ///   (6) 末尾再帰
    def gameLoop(fontAtlas: FontAtlas,
                  boldFontAtlas: FontAtlas,
                  waitQueue: Game.CommandWaitQueue.WaitQueue[r],
                  scene: Scene[NodeTag]):
                  Unit \ {GameEngine.Game, GameEngine.Audio, Dialogue.Session,
                          Dialogue.SceneView.Inbox, Dialogue.SceneView.CommandInbox,
                          Yarn.VariableAccess,
                          Editor.EditorState,
                          EditHistory.Rewind, Fs.FileRead, Fs.FileWrite,
                          IO, Chan, NonDet, r} =
        if (GameEngine.Game.shouldClose()
            or GameEngine.Game.isKeyPressed(GameEngine.Key.Escape)) ()
        else {
            let dt = GameEngine.Game.getDeltaTime();
            // (1) エディタ入力を最優先
            let afterEditor = Editor.handleInput(scene);
            // (2) エディタ ON ならゲーム更新スキップ
            //     コマンド処理（CommandRouter）はエディタ ON 中も走らせる。
            //     wait のカウントダウンは外部時計で進めるため、エディタで止まると VM が
            //     永久に動かなくなって不便なので。
            let updated =
                if (Editor.isOn()) afterEditor
                else afterEditor
                    |> GameEngine.handleInput
                    |> GameEngine.process(delta = dt, paused = false);
            // (3) Yarn コマンド処理。`runCommand` で別キュー化された command 文字列を
            // すべて取り出し、音再生 / 変数書き込み / wait 登録 / fallback ログに振り分ける。
            // wait 完了時は CommandRouter 内で `submitCommandDone` を発火する。
            let afterCommands =
                Game.CommandRouter.processCommands(waitQueue, delta = dt, updated);
            // (4) ホットリロード判定。再構築時は対話の進行状態（UIState）を維持し、
            // 表示ノード（Body / Transition / Indicator / layer の visible）も
            // 旧状態から再同期する。エディタ ON 中は `process` が走らないので、
            // ここで `syncDisplay` を呼んでおかないと Body の text が空文字
            // （scene.json のデフォルト）のままになって会話が消えて見える。
            let next =
                if (Editor.pollReload()) {
                    let preservedState = DialogueScene.getState(afterCommands);
                    buildScene(fontAtlas, boldFontAtlas)
                        |> DialogueScene.mapState(_ -> preservedState)
                        |> DialogueScene.syncDisplay(preservedState)
                }
                else afterCommands;
            // (5) エディタオーバーレイ → 描画
            GameEngine.render(Editor.applyOverlay(fontAtlas, next));
            gameLoop(fontAtlas, boldFontAtlas, waitQueue, next)
        }
}
