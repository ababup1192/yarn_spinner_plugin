/// ゲーム本体エントリ。`yarn/output.json` を読み込み、`DialogueScene` レイヤを
/// 1 枚積んで対話デモを駆動する。
///
/// engine-guide / scene-editor / game-loop の各規約に揃えた構成：
///   - `NodeTag.Dialogue(DialogueScene.Data)` でレイヤ状態を NodeTag に内包
///   - `InputHandler[NodeTag]` は `DialogueScene.input` に委譲するだけ（dispatch のみ）
///   - `mod Game` は配線役。シーン構築・ロジックは XxxScene 側
///   - `gameLoop` は固定パイプライン: 終了判定 → handleInput → drainEvents → syncFromData → render

/// Scene[s] のジェネリック s に当てるタグ。
/// 対話レイヤだけがゲームロジックを持つ（root の `Dialogue.UIState` に状態を集約）。
pub enum NodeTag {
    case NoTag
    case Dialogue(Dialogue.UIState)
}

/// Node 実装。Dialogue レイヤの `process` を `DialogueScene.process` に委譲する。
/// `process` 内で auto-advance が `Session.submitAdvance` を、新行検知が
/// `GameEngine.Audio.playAudio` を発火するため Aef は 3 つ必要。
instance Node[NodeTag] {
    type Aef = { Dialogue.SceneView.Pump, Dialogue.Session, GameEngine.Audio }

    redef process(delta: Duration.Duration, node: EngineNode[NodeTag],
                   _path: NodePath, scene: Scene[NodeTag]):
                    (EngineNode[NodeTag], Scene[NodeTag])
                    \ {Dialogue.SceneView.Pump, Dialogue.Session, GameEngine.Audio} =
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
    /// 対話関連の handler 連結（Runner / WaitOnly / SceneView+Pump）は
    /// `Dialogue.withDialog` に閉じ込めてあり、region / event queue は外には漏れない。
    pub def start(initialHp: Int32): Unit \ {GameEngine.Game, GameEngine.Audio, Fs.FileRead, IO, Chan, NonDet} =
        // 注意: Flix では `project` は予約語のため変数名に使えない。
        let yarnProject =
            loadProject()
                |> Yarn.overrideInitialFloat("\$hp", Int32.toFloat64(initialHp));
        run {
            Dialogue.Session.start("Start");
            gameLoop(buildScene())
        } with Dialogue.withDialog(yarnProject)

    /// メインループ。Scene 操作は持たず、エンジン提供のパイプラインを順に呼ぶだけ：
    ///   終了判定 → handleInput → process → render → 末尾再帰
    /// 入力からのイベント取り込み（queue → Data → 描画ノード同期）は
    /// `DialogueScene.process` が Node trait 経由で受け持つ。
    /// `handleInput` を `process` より先に置いているのは、押下キーで生まれた
    /// イベントを同フレーム内で消化して次の `render` に乗せるため。
    def gameLoop(scene: Scene[NodeTag]):
                  Unit \ {GameEngine.Game, GameEngine.Audio, Dialogue.Session,
                          Dialogue.SceneView.Pump, IO, Chan, NonDet} =
        if (GameEngine.Game.shouldClose()
            or GameEngine.Game.isKeyPressed(GameEngine.Key.Escape)) ()
        else {
            let dt = GameEngine.Game.getDeltaTime();
            let nextScene =
                scene
                    |> GameEngine.handleInput
                    |> GameEngine.process(delta = dt, paused = false);
            GameEngine.render(nextScene);
            gameLoop(nextScene)
        }
}
