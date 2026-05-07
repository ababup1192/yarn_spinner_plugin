/// 対話 UI シーン。`NodeTag.Dialogue(Data)` を root に持つ CanvasLayer 1 枚で
/// 「画面下半分の対話パネル」を実現する。
///
/// 役割（scene-editor / engine-guide 準拠）:
///   (A) Types       — `Data`（表示状態）
///   (B) Constants   — ノード名・パス・レイアウト数値・フォント名・drawLayer
///   (C) 構築        — `addDialogueLayer`
///   (D) ロジック    — `input` / `drainEvents` / `syncFromData` と純粋ヘルパ群
///   (E) Boilerplate — `mapData` / `getData`
///
/// SceneView handler から流れてくる `ViewEvent` は `MutDeque` に貯められ、
/// gameLoop が毎フレーム `drainEvents` で消化する。これで「`handleInput` が
/// 戻すシーン」と「SceneView が書いたシーン」のマージ問題を回避している。
mod DialogueScene {
    use Dialogue.StubView.ViewEvent
    use Dialogue.StubView.ViewEvent.{PresentedLine, PresentedOptions, Dismissed, Command, Complete}

    // ════════════════════════════════════════════════════════════════════════
    // (A) Types
    // ════════════════════════════════════════════════════════════════════════

    /// 対話レイヤの表示状態。`NodeTag.Dialogue(Data)` でレイヤ root に持つ。
    pub type alias Data = {
        text     = String,        // line モードの本文。options モードでは空。
        options  = List[String],  // 選択肢中なら non-empty。
        cursor   = Int32,         // options 内の選択中 index（0 始まり）。
        visible  = Bool           // 完了後 / 未開始は false。
    }

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
    /// 起動時の Data は `emptyData`（visible=false）なので、`Dialog.start` 後の
    /// 最初の `presentLine` がキューに入って `drainEvents` で反映されるまで
    /// 何も表示されない。
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
                EngineNode.CanvasLayerWithState(layer, NodeTag.Dialogue(emptyData())))
            |> Scene.addChild(layerName(), bgName(),
                EngineNode.ColorRectWithState(bg, NodeTag.NoTag))
            |> Scene.addChild(layerName(), bodyName(),
                EngineNode.RichTextLabelWithState(body, NodeTag.NoTag))

    // ════════════════════════════════════════════════════════════════════════
    // (D) ロジック
    // ════════════════════════════════════════════════════════════════════════

    // ── Data の純粋ヘルパ ──

    /// 初期状態（未開始 = 非表示）。
    pub def emptyData(): Data = {
        text = "",
        options = Nil,
        cursor = 0,
        visible = false
    }

    /// `presentLine` を反映した Data。
    pub def lineData(text: String): Data = {
        text = text,
        options = Nil,
        cursor = 0,
        visible = true
    }

    /// `presentOptions` を反映した Data。カーソルは先頭にリセット。
    pub def optionsData(options: List[String]): Data = {
        text = "",
        options = options,
        cursor = 0,
        visible = true
    }

    /// `dialogueComplete` を反映した Data（表示を消す）。
    pub def closedData(): Data = emptyData()

    /// 本文として表示する文字列を Data から組み立てる。
    /// - options 空 → 本文 text をそのまま返す
    /// - options 非空 → カーソル行に `> `、それ以外に `  ` を付けて改行連結
    pub def formatBody(data: Data): String =
        if (List.isEmpty(data#options)) data#text
        else
            List.mapWithIndex((index, option) ->
                if (index == data#cursor) "> ${option}"
                else "  ${option}",
                data#options)
                |> String.intercalate("\n")

    /// `delta` だけカーソルを動かした Data を返す。
    /// 範囲外は wrap-around（先頭から末尾へ、末尾から先頭へ）。
    /// options が空のときは Data を変えない。
    pub def moveCursor(delta: Int32, data: Data): Data =
        let optionCount = List.length(data#options);
        if (optionCount <= 0) data
        else {
            let raw = data#cursor + delta;
            let normalized =
                if (raw < 0) optionCount - 1
                else if (raw >= optionCount) 0
                else raw;
            { cursor = normalized | data }
        }

    // ── 入力ディスパッチ（`InputHandler[NodeTag]` から委譲される）──

    /// 1 キー入力を対話 UI として解釈する。
    ///   - 確定キー（Z/Space/Enter）: options 空なら `submitAdvance`、非空なら `submitSelect`
    ///   - 上 (Up/W): カーソル -1
    ///   - 下 (Down/S): カーソル +1
    /// 表示中（visible=true）でないキーは黙って無視する。
    pub def input(key: GameEngine.Key, scene: Scene[NodeTag]):
                   Scene[NodeTag] \ Dialogue.Dialog =
        let data = getData(scene);
        if (not data#visible) scene
        else {
            let isConfirm =
                key == GameEngine.Key.Z
                or key == GameEngine.Key.Space
                or key == GameEngine.Key.Enter;
            let isUp = key == GameEngine.Key.Up or key == GameEngine.Key.W;
            let isDown = key == GameEngine.Key.Down or key == GameEngine.Key.S;
            if (isConfirm) {
                if (List.isEmpty(data#options)) Dialogue.Dialog.submitAdvance()
                else Dialogue.Dialog.submitSelect(data#cursor);
                scene
            } else if (isUp)
                mapData(d -> moveCursor(-1, d), scene)
            else if (isDown)
                mapData(d -> moveCursor(1, d), scene)
            else scene
        }

    // ── ViewEvent → Scene への反映 ──

    /// 1 件の `ViewEvent` を Scene に反映する（Data の差し替えのみ）。
    /// 本文や可視性の描画反映は `syncFromData` が担う。
    def applyEvent(event: ViewEvent, scene: Scene[NodeTag]): Scene[NodeTag] =
        match event {
            case PresentedLine(text)       => mapData(_ -> lineData(text), scene)
            case PresentedOptions(options) => mapData(_ -> optionsData(options), scene)
            case Dismissed                 => scene
            case Command(_)                => scene
            case Complete                  => mapData(_ -> closedData(), scene)
        }

    /// `MutDeque` に貯まったイベントを順に消化し、最終的な Scene を返す。
    /// 末尾再帰でキューを空にする。
    pub def drainEvents(queue: MutDeque[ViewEvent, r], scene: Scene[NodeTag]):
                         Scene[NodeTag] \ r =
        match MutDeque.popFront(queue) {
            case Some(event) => drainEvents(queue, applyEvent(event, scene))
            case None        => scene
        }

    // ── Data → 描画ノード（RichTextLabel・可視性）の同期 ──

    /// 現在の Data に応じて、レイヤの可視性と本文 RichTextLabel のテキストを更新する。
    /// `drainEvents` の直後（および入力でカーソル移動した直後の同フレーム描画時）に呼ぶ。
    pub def syncFromData(scene: Scene[NodeTag]): Scene[NodeTag] =
        let data = getData(scene);
        scene
            |> Scene.mapEngineNode(layerPath(), engineNode ->
                CanvasItem.setVisible(data#visible, engineNode))
            |> Scene.mapEngineNode(bodyPath(), engineNode ->
                EngineNode.mapRichTextLabel(label ->
                    RichTextLabel.setText(formatBody(data), label), engineNode))

    // ════════════════════════════════════════════════════════════════════════
    // (E) Boilerplate — レイヤ Data の取得 / 変換
    // ════════════════════════════════════════════════════════════════════════

    /// レイヤノードに紐づく `Data` を取り出す。レイヤが居なければ `bug!`。
    /// 起動時に `addDialogueLayer` を必ず呼ぶ前提。
    pub def getData(scene: Scene[NodeTag]): Data =
        match Scene.getState(layerPath(), scene) {
            case Some(NodeTag.Dialogue(data)) => data
            case _ => bug!("DialogueScene.getData: dialogue layer not found")
        }

    /// レイヤノードに紐づく `Data` を関数で変換する。
    /// レイヤが居ない / 別タグなら何もしない（防御的）。
    pub def mapData(f: Data -> Data, scene: Scene[NodeTag]): Scene[NodeTag] =
        Scene.mapState(layerPath(), tag -> match tag {
            case NodeTag.Dialogue(data) => NodeTag.Dialogue(f(data))
            case other                  => other
        }, scene)
}
