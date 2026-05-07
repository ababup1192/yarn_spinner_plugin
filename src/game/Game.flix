/// ゲーム本体エントリ。`yarn/output.json` を読み込み、`DialogueScene` レイヤを
/// 1 枚積んで対話デモを駆動する。
///
/// engine-guide / scene-editor / game-loop の各規約に揃えた構成：
///   - `NodeTag.Dialogue(DialogueScene.Data)` でレイヤ状態を NodeTag に内包
///   - `InputHandler[NodeTag]` は `DialogueScene.input` に委譲するだけ（dispatch のみ）
///   - `mod Game` は配線役。シーン構築・ロジックは XxxScene 側
///   - `gameLoop` は固定パイプライン: 終了判定 → handleInput → drainEvents → syncFromData → render

/// Scene[s] のジェネリック s に当てるタグ。
/// 対話レイヤだけがゲームロジックを持つ（root の Data に状態を集約）。
pub enum NodeTag {
    case NoTag
    case Dialogue(DialogueScene.Data)
}

/// 必要最低限の Node 実装（ライフサイクル副作用なし）。
instance Node[NodeTag] {
    type Aef = {}
}

/// 入力ハンドラ。`Dialogue.Dialog` を発行し、対話 UI ロジックは
/// `DialogueScene.input` にまるごと委譲する。
instance InputEvent.InputHandler[NodeTag] {
    type Aef = { Dialogue.Dialog }

    redef onKeyPressed(key: GameEngine.Key, scene: Scene[NodeTag]):
                        Scene[NodeTag] \ { Dialogue.Dialog } =
        DialogueScene.input(key, scene)
}

mod Game {
    use Dialogue.StubView.ViewEvent
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
    def buildScene(): Scene[NodeTag] \ GameEngine.Game =
        let fontAtlas = GameEngine.Game.getFontAtlas(DialogueScene.fontName());
        Scene.empty()
            |> DialogueScene.addDialogueLayer(
                {viewportWidth = designWi(), viewportHeight = designHi()},
                fontAtlas)

    // ════════════════════════════════════════════════════════════════════════
    // start / gameLoop
    // ════════════════════════════════════════════════════════════════════════

    /// ゲーム起動エントリ。`initialHp` で Yarn 変数 `$hp` の初期値を外から注入する。
    /// fixture 側のデフォルトは 0 のため、注入しないと「HP 0 ある」表示になる。
    ///
    /// 起動時 1 回だけ実行する常駐セットアップ:
    ///   1. `region rc` で MutDeque（イベントキュー）を確保
    ///   2. handler 連結（外側 → 内側）: SceneView → Commands → Runner
    ///   3. `Dialog.start("Start")` で対話を開始
    ///   4. `gameLoop` に渡す
    pub def start(initialHp: Int32): Unit \ {GameEngine.Game, Fs.FileRead, IO, Chan, NonDet} =
        region rc {
            // 注意: Flix では `project` は予約語のため変数名に使えない。
            let yarnProject =
                loadProject()
                    |> Yarn.overrideInitialFloat("\$hp", Int32.toFloat64(initialHp));
            let scene0 = buildScene();
            let queue: MutDeque[ViewEvent, rc] = MutDeque.empty(rc);
            Dialogue.SceneView.withSceneView(rc, queue, () ->
                Dialogue.Commands.withWaitOnly(() ->
                    Dialogue.Runner.withRunner(rc, yarnProject, () -> {
                        Dialogue.Dialog.start("Start");
                        gameLoop(queue, scene0)
                    })))
        }

    /// メインループ。固定パイプライン:
    ///   終了判定 → handleInput → drainEvents → syncFromData → render → 末尾再帰
    /// `handleInput` の中で `DialogueScene.input` が `Dialog.submit*` を呼ぶと、
    /// `withRunner` ハンドラが VM を pump し、結果のイベントを SceneView ハンドラが
    /// `queue` に push する。`drainEvents` で次フレームのシーンに反映される。
    def gameLoop(queue: MutDeque[ViewEvent, r], scene: Scene[NodeTag]):
                  Unit \ {GameEngine.Game, Dialogue.Dialog, IO, Chan, NonDet, r} =
        if (GameEngine.Game.shouldClose()
            or GameEngine.Game.isKeyPressed(GameEngine.Key.Escape)) ()
        else {
            let nextScene =
                GameEngine.handleInput(scene)
                    |> DialogueScene.drainEvents(queue)
                    |> DialogueScene.syncFromData;
            GameEngine.render(nextScene);
            gameLoop(queue, nextScene)
        }
}
