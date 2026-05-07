/// 対話 UI シーン。`NodeTag.Dialogue(Dialogue.UIState)` を root に持つ
/// CanvasLayer 1 枚で「画面下部の対話パネル」を実現する。
///
/// 状態モデル（`UIState`）と純粋遷移は `mod Dialogue` 側に閉じる。本モジュールは
/// Scene 固有の配置・描画ノード同期・入力配線のみ。
///
/// パネル構成:
///   CanvasLayer ("Dialogue", drawLayer = 10, position = panel 左上)
///     ├── WhiteBorder (ColorRect 白, alpha = 1.0, zIndex 0)
///     ├── BlackInner  (ColorRect 黒, alpha = 0.85, zIndex 1) — 白枠の内側 3px インセット
///     ├── Transition  (RichTextLabel, zIndex 2) — スクロール+フェード中の旧行
///     └── Body        (RichTextLabel, zIndex 3) — 現在表示中の行（typewriter）
mod DialogueScene {
    use Dialogue.UIState
    use Dialogue.Transition

    // ════════════════════════════════════════════════════════════════════════
    // (B) Constants — ノード名・パス・レイアウト・描画設定
    // ════════════════════════════════════════════════════════════════════════

    /// レイヤ（CanvasLayer）の名前。
    pub def layerName(): String = "Dialogue"

    // 子ノード名は scene.json と一致させる（変更時は両方を更新）
    def bodyName(): String = "Body"
    def transitionName(): String = "Transition"
    def indicatorName(): String = "Indicator"

    /// レイヤへの NodePath。
    pub def layerPath(): NodePath = layerName() :: Nil

    /// 本文・transition・インジケータへの NodePath。
    def bodyPath(): NodePath = layerName() :: bodyName() :: Nil
    def transitionPath(): NodePath = layerName() :: transitionName() :: Nil
    def indicatorPath(): NodePath = layerName() :: indicatorName() :: Nil

    /// 本パネルが使うフォントの論理名（Main.flix の fontManifest と一致）。
    pub def fontName(): String = "default"

    // ── レイアウト数値（design 単位 px、解像度 320×240 を想定）──
    //
    // ノードの配置・サイズ・色などの構築時の値は scene.json 側に固定値として持つ。
    // ここに残るのは「ランタイム更新（updateTransition 等）で使う数値」だけ。

    /// シーン定義 JSON のパス。
    def sceneJsonPath(): String = "src/scenes/DialogueScene.scene.json"

    /// 白枠の太さ（design px）。scene.json の Inner / Body / Transition の position と
    /// 揃っており、transition のスクロール開始 Y 計算でも使う。
    def borderWidth(): Float64 = 3.0

    /// 本文ノードの内側余白（白枠の内側からさらに引く design px）。
    /// transition のスクロール開始 Y 計算で使う。
    def bodyInnerMargin(): Float64 = 6.0

    /// transition の上方向スクロール量（design px）。
    /// 行高さ × 行数（1 行 8 px × 3 行 = 24 px）でちょうど全行が body 上辺に達する。
    def transitionScrollPx(): Float64 = 24.0

    /// 1 行分の表示高さ（design px）。BestTen-DOT を bake 16 / display 8 で使うので
    /// lineHeight ≈ font の em (16) を 0.5 倍した 8 px。transition のスナップ閾値計算に使う。
    def transitionLineHeight(): Float64 = 8.0

    // ════════════════════════════════════════════════════════════════════════
    // (C) 構築
    // ════════════════════════════════════════════════════════════════════════

    /// 既存の Scene に対話レイヤを 1 枚積む。
    /// ノードツリーの構造（位置・サイズ・色など）は `DialogueScene.scene.json` に持つ。
    /// scene.json は 320×240 の design 解像度を前提にした固定値で記述されている。
    /// JSON 側はタグを持たず、ロード後に layer ノードへ
    /// `NodeTag.Dialogue(emptyState(jrpgProfile))` を注入する（visible=false）。
    /// scene.json のレイアウトが JRPG 風 3 行パネル前提なので profile も JRPG 固定で良い。
    pub def addDialogueLayer(fontAtlas: FontAtlas,
                              scene: Scene[NodeTag]):
                              Scene[NodeTag] \ {GameEngine.Game, Fs.FileRead} =
        SceneLoader.loadSceneWithFont(sceneJsonPath(), fontAtlas,
            SceneLoader.constTagParser(NodeTag.NoTag), scene)
            |> Scene.setState(layerPath(),
                NodeTag.Dialogue(Dialogue.emptyState(Dialogue.jrpgProfile())))

    // ════════════════════════════════════════════════════════════════════════
    // (D) ロジック — 入力ディスパッチと process
    // ════════════════════════════════════════════════════════════════════════

    /// 1 キー入力を対話 UI として解釈する。
    ///   - 確定キー（Z/Space/Enter）:
    ///       * options モード → tap → `submitSelect`
    ///       * typewriter 途中 → tap → `forceFullReveal`
    ///       * `shouldShowAdvanceIndicator` のとき → tap → 手動 `submitAdvance`
    ///       * それ以外（auto-advance 中・transition 中など） → 無視
    ///   - 上 (Up/W): カーソル -1
    ///   - 下 (Down/S): カーソル +1
    /// 表示中（visible=true）でないキーは黙って無視する。
    pub def input(key: GameEngine.Key, scene: Scene[NodeTag]):
                   Scene[NodeTag] \ {Dialogue.Session, GameEngine.Audio} =
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
                if (not List.isEmpty(state#options)) {
                    GameEngine.Audio.playAudio("tap");
                    Dialogue.Session.submitSelect(state#cursor);
                    scene
                } else if (not Dialogue.isLineFullyRevealed(state)) {
                    GameEngine.Audio.playAudio("tap");
                    mapState(s -> Dialogue.forceFullReveal(s), scene)
                } else if (Dialogue.shouldShowAdvanceIndicator(state)) {
                    GameEngine.Audio.playAudio("tap");
                    Dialogue.Session.submitAdvance();
                    scene
                } else scene
            } else if (isUp)
                mapState(s -> Dialogue.moveCursor(-1, s), scene)
            else if (isDown)
                mapState(s -> Dialogue.moveCursor(1, s), scene)
            else scene
        }

    /// レイヤノードの `process` ライフサイクル。
    /// 1. `Pump.drain` で 1 フレーム分のイベントを取り出し、`Dialogue.applyEvent` で状態を進める
    /// 2. `Dialogue.tick(dt)` で typewriter / transition / 経過秒を進める
    /// 3. lines が増えたフレーム（新しい行が表示開始）で talk 効果音を鳴らす
    /// 4. 継続 line の typewriter 完了などで `shouldAutoAdvance` が立っていれば
    ///    `Session.submitAdvance` を発火（次フレームの drain で取り込まれる）
    /// 5. 新しい layer ノードと、本文 / transition / インジケータを更新した scene を返す
    pub def process(delta: Duration.Duration,
                     layer: CanvasLayer,
                     state: Dialogue.UIState,
                     scene: Scene[NodeTag]):
                     (EngineNode[NodeTag], Scene[NodeTag])
                     \ {Dialogue.SceneView.Pump, Dialogue.Session, GameEngine.Audio} =
        let events = Dialogue.SceneView.Pump.drain();
        let dt = Duration.toSeconds(delta);
        let newState =
            List.foldLeft((s, event) -> Dialogue.applyEvent(event, s), state, events)
                |> Dialogue.tick(dt);
        // 行が新しく追加されたフレームで talk SE を頭から再生（自然減衰で勝手に止まる）
        if (List.length(newState#lines) > List.length(state#lines))
            GameEngine.Audio.playAudio("talk")
        else ();
        if (Dialogue.shouldAutoAdvance(newState)) Dialogue.Session.submitAdvance() else ();
        let newLayer = CanvasItem.setVisible(newState#visible, layer);
        let newNode = EngineNode.CanvasLayerWithState(newLayer, NodeTag.Dialogue(newState));
        let newScene =
            scene
                |> updateBody(newState)
                |> updateTransition(newState)
                |> updateIndicator(newState);
        (newNode, newScene)

    /// 本文 RichTextLabel のテキストを最新状態から同期する。
    def updateBody(state: UIState, scene: Scene[NodeTag]): Scene[NodeTag] =
        Scene.mapEngineNode(bodyPath(), engineNode ->
            EngineNode.mapRichTextLabel(label ->
                RichTextLabel.setText(Dialogue.formatBody(state), label),
                engineNode),
            scene)

    /// 続行 ▼ インジケータの表示/非表示を同期する。
    /// 表示すべきタイミング（typewriter 完了 + transition なし + line モード）かつ
    /// blink 周期が ON のときだけインジケータ文字を入れる。それ以外は空文字で隠す。
    def updateIndicator(state: UIState, scene: Scene[NodeTag]): Scene[NodeTag] =
        let visible =
            Dialogue.shouldShowAdvanceIndicator(state) and Dialogue.isBlinkOn(state);
        let text = if (visible) state#profile#advanceIndicatorGlyph else "";
        Scene.mapEngineNode(indicatorPath(), engineNode ->
            EngineNode.mapLabel2D(label -> Label2D.setText(text, label), engineNode),
            scene)

    /// transition RichTextLabel を「上にスクロール → 上辺に当たった行は消える」流儀で同期する。
    ///   - ラベル position.y を `bodyOrigin.y - progress * scrollPx` で連続的に上へ動かす
    ///   - 各行は scroll 量が「自分の bottom が body 上辺を越える値」を超えたら "" にスナップ
    ///   - スナップする頃にはその行は border 帯（白）に入って白×白で隠れているので、
    ///     見た目は「上にスーッ → 上辺で消える」となる
    def updateTransition(state: UIState, scene: Scene[NodeTag]): Scene[NodeTag] =
        let bodyOrigin: Vec2.Vec2 = {
            x = borderWidth() + bodyInnerMargin(),
            y = borderWidth() + bodyInnerMargin()
        };
        match Dialogue.transitionView(state) {
            case None =>
                Scene.mapEngineNode(transitionPath(), engineNode ->
                    engineNode
                        |> EngineNode.mapRichTextLabel(label -> RichTextLabel.setText("", label))
                        |> Node2D.setPosition(bodyOrigin)
                        |> CanvasItem.setModulate({r = 1.0f32, g = 1.0f32, b = 1.0f32}),
                    scene)
            case Some(transition) =>
                let scrollY = transition#progress * transitionScrollPx();
                // 各行 N の bottom が body 上辺を越える scroll = (N+1)*lineHeight
                let displayLines = List.mapWithIndex((index, line) -> {
                    let exitScroll =
                        (Int32.toFloat64(index) + 1.0) * transitionLineHeight();
                    if (scrollY >= exitScroll) ""
                    else line
                }, transition#oldLines);
                let text = String.intercalate("\n", displayLines);
                let position: Vec2.Vec2 = {
                    x = bodyOrigin#x,
                    y = bodyOrigin#y - scrollY
                };
                Scene.mapEngineNode(transitionPath(), engineNode ->
                    engineNode
                        |> EngineNode.mapRichTextLabel(label -> RichTextLabel.setText(text, label))
                        |> Node2D.setPosition(position)
                        |> CanvasItem.setModulate({r = 1.0f32, g = 1.0f32, b = 1.0f32}),
                    scene)
        }

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
