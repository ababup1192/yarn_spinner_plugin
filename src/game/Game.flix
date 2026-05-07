/// 最小限のゲーム定義。
/// 現状はウィンドウを開いて Esc キーでで閉じるだけ。
/// Yarn Spinner プラグインの組み込みは別フェーズで進める。

/// Scene[s] のジェネリック s に当てるダミー型。
/// 全ノードは `NoTag` を持ち、ゲームロジックは持たない。
pub enum NodeTag {
    case NoTag
}

/// 必要最低限の Node 実装（すべてデフォルト）。
instance Node[NodeTag] {
    type Aef = {}
}

/// 必要最低限の入力ハンドラ（すべてデフォルト）。
instance InputEvent.InputHandler[NodeTag] {
    type Aef = {}
}

mod Game {

    /// デザイン解像度（ロジック側の基準）。
    pub def designWi(): Int32 = 320
    pub def designHi(): Int32 = 240

    /// 初期ウィンドウサイズ（OS ピクセル）。
    pub def windowWi(): Int32 = 960
    pub def windowHi(): Int32 = 720

    /// ゲーム起動エントリ。
    /// 空のシーンを描画し続け、Esc キーかウィンドウを閉じると終了する。
    pub def start(): Unit \ {GameEngine.Game, Chan, NonDet, IO} =
        gameLoop(Scene.empty())

    /// メインループ。終了判定 → 描画 → 末尾再帰。
    def gameLoop(scene: Scene[NodeTag]): Unit \ {GameEngine.Game, Chan, NonDet, IO} =
        if (GameEngine.Game.shouldClose() or
            GameEngine.Game.isKeyPressed(GameEngine.Key.Escape)) ()
        else {
            GameEngine.render(scene);
            gameLoop(scene)
        }
}
