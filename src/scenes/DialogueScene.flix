/// 対話 UI シーン。`NodeTag.Dialogue(Dialogue.UIState)` を root に持つ
/// CanvasLayer 1 枚で「画面下半分の対話パネル」を実現する。
///
/// 状態モデル（`UIState`）と純粋遷移（`applyEvent` / `moveCursor` /
/// `formatBody`）は `mod Dialogue` 側にあるので、本モジュールは Scene 固有の
/// 配置・描画ノード同期・入力配線だけを担当する。
///
/// 役割（scene-editor / engine-guide 準拠）:
///   (B) Constants   — ノード名・パス・レイアウト数値・フォント名・drawLayer
///   (C) 構築        — `addDialogueLayer`
///   (D) ロジック    — `input` / `process`（と内部の `syncFromData`）
///   (E) Boilerplate — `mapState` / `getState`
mod DialogueScene {
    use Dialogue.UIState

    // ════════════════════════════════════════════════════════════════════════
    // (B) Constants — ノード名・パス・レイアウト・描画設定
    // ════════════════════════════════════════════════════════════════════════

    /// レイヤ（CanvasLayer）の名前。
    pub def layerName(): String = "Dialogue"

    /// 半透明背景（ColorRect）の名前。
    def bgName(): String = "Bg"

    /// 本文（RichTextLabel）の名前。
    def bodyName(): String = "Body"

    /// レイヤへの NodePath。
    pub def layerPath(): NodePath = layerName() :: Nil

    /// 本文ノードへの NodePath。
    def bodyPath(): NodePath = layerName() :: bodyName() :: Nil

    /// 本パネルが使うフォントの論理名（Main.flix の fontManifest と一致）。
    pub def fontName(): String = "default"

    /// 対話パネルの高さ（px）。デザイン解像度の下半分にあたる。
    def panelHeight(): Int32 = 96

    /// 本文の左右マージン（px）。
    def bodyMarginX(): Float64 = 16.0

    /// 本文の上下マージン（px）。
    def bodyMarginY(): Float64 = 8.0

    /// 本文フォントサイズ（design 単位 px）。fontManifest の bake サイズと
    /// 揃えて 1:1 比にすると、画面拡大率（design→window）に対して各 atlas pixel が
    /// 整数倍ブロックで描画され pixel-perfect になる。
    def bodyFontSize(): Float64 = 16.0

    /// CanvasLayer の描画レイヤ番号（HUD として最前面に来る大きめ）。
    def drawLayer(): Int32 = 10

    /// 本文 RichTextLabel の zIndex。背景 ColorRect (zIndex=0) より大きく
    /// しないと描画順が不定になり、Bg がグリフを部分的に上書きして
    /// 「文字の一部が消える」現象が出る。
    def bodyZIndex(): Int32 = 1

    /// 半透明背景の不透明度（0 = 完全透明、1 = 不透明）。
    def panelAlpha(): Float32 = 0.8f32

    // ════════════════════════════════════════════════════════════════════════
    // (C) 構築
    // ════════════════════════════════════════════════════════════════════════

    /// 既存の Scene に対話レイヤを 1 枚積む。
    /// 起動時の状態は `Dialogue.emptyState`（visible=false）なので、
    /// 最初の `presentLine` がキューに入って `process` で反映されるまで何も表示されない。
    ///
    /// `viewport` はゲームのデザイン解像度（Game.flix の designWi/designHi）。
    /// パネルはその下端に貼り付くように配置される。
    pub def addDialogueLayer(viewport: {viewportWidth = Int32, viewportHeight = Int32},
                              fontAtlas: FontAtlas,
                              scene: Scene[NodeTag]): Scene[NodeTag] =
        let panelOriginY =
            Int32.toFloat64(viewport#viewportHeight - panelHeight());
        let panelSize: Vec2.Vec2 = {
            x = Int32.toFloat64(viewport#viewportWidth),
            y = Int32.toFloat64(panelHeight())
        };
        let bodySize: Vec2.Vec2 = {
            x = panelSize#x - bodyMarginX() * 2.0,
            y = panelSize#y - bodyMarginY() * 2.0
        };
        let layer =
            CanvasLayer.make(drawLayer())
                |> Node2D.setPosition({x = 0.0, y = panelOriginY});
        let bg =
            ColorRect.make(panelSize, {r = 0.0f32, g = 0.0f32, b = 0.0f32})
                |> ColorRect.setAlpha(panelAlpha());
        let body =
            RichTextLabel.make("", fontAtlas, bodyFontSize(), bodySize)
                |> CanvasItem.setZIndex(bodyZIndex())
                |> Node2D.setPosition({x = bodyMarginX(), y = bodyMarginY()});
        scene
            |> Scene.addNode(layerName(),
                EngineNode.CanvasLayerWithState(layer, NodeTag.Dialogue(Dialogue.emptyState())))
            |> Scene.addChild(layerName(), bgName(),
                EngineNode.ColorRectWithState(bg, NodeTag.NoTag))
            |> Scene.addChild(layerName(), bodyName(),
                EngineNode.RichTextLabelWithState(body, NodeTag.NoTag))

    // ════════════════════════════════════════════════════════════════════════
    // (D) ロジック — 入力ディスパッチと process
    // ════════════════════════════════════════════════════════════════════════

    /// 1 キー入力を対話 UI として解釈する。
    ///   - 確定キー（Z/Space/Enter）: options 空なら `submitAdvance`、非空なら `submitSelect`
    ///   - 上 (Up/W): カーソル -1
    ///   - 下 (Down/S): カーソル +1
    /// 表示中（visible=true）でないキーは黙って無視する。
    pub def input(key: GameEngine.Key, scene: Scene[NodeTag]):
                   Scene[NodeTag] \ Dialogue.Session =
        let state = getState(scene);
        if (not state#visible) scene
        else {
            let isConfirm =
                key == GameEngine.Key.Z
                or key == GameEngine.Key.Space
                or key == GameEngine.Key.Enter;
            let isUp = key == GameEngine.Key.Up or key == GameEngine.Key.W;
            let isDown = key == GameEngine.Key.Down or key == GameEngine.Key.S;
            if (isConfirm) {
                if (List.isEmpty(state#options)) Dialogue.Session.submitAdvance()
                else Dialogue.Session.submitSelect(state#cursor);
                scene
            } else if (isUp)
                mapState(s -> Dialogue.moveCursor(-1, s), scene)
            else if (isDown)
                mapState(s -> Dialogue.moveCursor(1, s), scene)
            else scene
        }

    /// レイヤノードの `process` ライフサイクル。`Node[NodeTag]` instance から委譲される。
    /// 1 フレーム分のイベントを `Dialogue.SceneView.Pump.drain` で取り出し、
    /// `Dialogue.applyEvent` で状態を進めてから本文を同期する。
    /// 子ノード（Bg / Body）には別の処理は無いので、ここで scene を最後まで仕上げる。
    pub def process(node: EngineNode[NodeTag], _path: NodePath, scene: Scene[NodeTag]):
                     (EngineNode[NodeTag], Scene[NodeTag]) \ Dialogue.SceneView.Pump =
        let events = Dialogue.SceneView.Pump.drain();
        let updatedScene =
            List.foldLeft((s, event) ->
                mapState(state -> Dialogue.applyEvent(event, state), s),
                scene, events)
                |> syncFromData;
        (node, updatedScene)

    /// 現在の状態に応じて、レイヤの可視性と本文 RichTextLabel のテキストを更新する。
    /// `process` のイベント反映直後と、入力でカーソル移動した直後の同フレーム描画前に呼ぶ。
    def syncFromData(scene: Scene[NodeTag]): Scene[NodeTag] =
        let state = getState(scene);
        scene
            |> Scene.mapEngineNode(layerPath(), engineNode ->
                CanvasItem.setVisible(state#visible, engineNode))
            |> Scene.mapEngineNode(bodyPath(), engineNode ->
                EngineNode.mapRichTextLabel(label ->
                    RichTextLabel.setText(Dialogue.formatBody(state), label), engineNode))

    // ════════════════════════════════════════════════════════════════════════
    // (E) Boilerplate — レイヤ状態の取得 / 変換
    // ════════════════════════════════════════════════════════════════════════

    /// レイヤノードに紐づく `UIState` を取り出す。レイヤが居なければ `bug!`。
    /// 起動時に `addDialogueLayer` を必ず呼ぶ前提。
    pub def getState(scene: Scene[NodeTag]): UIState =
        match Scene.getState(layerPath(), scene) {
            case Some(NodeTag.Dialogue(state)) => state
            case _ => bug!("DialogueScene.getState: dialogue layer not found")
        }

    /// レイヤノードに紐づく `UIState` を関数で変換する。
    /// レイヤが居ない / 別タグなら何もしない（防御的）。
    pub def mapState(f: UIState -> UIState, scene: Scene[NodeTag]): Scene[NodeTag] =
        Scene.mapState(layerPath(), tag -> match tag {
            case NodeTag.Dialogue(state) => NodeTag.Dialogue(f(state))
            case other                   => other
        }, scene)
}
