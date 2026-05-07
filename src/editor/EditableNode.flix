// EditableNode — エディタが編集対象として扱うノードの抽出と矩形計算
//
// シーンを走査し Sprite2D / AnimatedSprite2D / TextureButton / Label2D / ColorRect を
// 編集対象として認識する。
// 各ノードの「画面上の表示矩形」（width / height と topLeftOffset）を計算して返すのが主な仕事。
//
// rootJsonIndex (root 名 → scene.json パス) に登録されていないルートに属する
// ノードは「JSON 書き戻し先が不明」として除外する（procedural 生成ノードや、
// エディタ自身のオーバーレイなど）

mod EditableNode {

    /// シーン上のノードを「編集対象として扱える形」で問い合わせるための文脈。
    pub type alias LookupCtx = {
        rootJsonIndex = Map[NodeName, String],
        scene = Scene[NodeTag]
    }

    /// 編集対象ノードの 1 件分の情報。
    pub type alias EditableEntry = {
        jsonPath = String,
        nodePath = NodePath,
        width = Float64,
        height = Float64,
        topLeftOffset = Vec2.Vec2
    }

    /// シーン全体を走査して編集対象ノードを抽出する。
    pub def collectAll(ctx: LookupCtx): List[EditableEntry] \ GameEngine.Game =
        Scene.preorderPaths(ctx#scene)
            |> List.filterMap(path -> buildEntry(ctx, path))

    /// 指定 NodePath の entry を 1 件取り出す。
    pub def findByNodePath(ctx: LookupCtx, nodePath: NodePath):
            Option[EditableEntry] \ GameEngine.Game =
        buildEntry(ctx, nodePath)

    /// Sprite2D / TextureButton の topLeftOffset 計算（中央基準なら半サイズ分マイナス）。
    pub def boxTopLeftOffset(centered: Bool, size: Vec2.Vec2): Vec2.Vec2 =
        if (centered) {x = -size#x / 2.0, y = -size#y / 2.0}
        else {x = 0.0, y = 0.0}

    /// Label2D の表示矩形を計算する。
    /// 横方向は HorizontalAlignment.Center のときのみ -width/2 オフセット、
    /// それ以外は 0（Left/Right/Fill は本実装では Left と同じ扱い）。
    pub def labelRectInfo(label: Label2D): {size = Vec2.Vec2, topLeftOffset = Vec2.Vec2} =
        let Label2D.Label2D(record) = label;
        let atlas = record#fontAtlas;
        let scale = record#fontSize / atlas#fontSize;
        let lines = TextLayout.splitLines(record#text);
        let lineWidths = List.map(lineChars -> {
            let advances = List.map(ch -> {
                let cp = TextLayout.charToCodePoint(ch);
                match Map.get(cp, atlas#glyphs) {
                    case Some(glyphMetrics) => glyphMetrics#advance
                    case None => 0.0
                }
            }, lineChars);
            TextLayout.totalAdvance(advances) * scale
        }, lines);
        let width = List.foldLeft(Float64.max, 0.0, lineWidths);
        let lineHeight = (atlas#ascent + atlas#descent + atlas#lineGap) * scale;
        let height = lineHeight * Int32.toFloat64(Int32.max(1, List.length(lines)));
        let topLeftOffset = match record#horizontalAlignment {
            case HorizontalAlignment.Center => {x = -width / 2.0, y = 0.0}
            case _                          => {x = 0.0, y = 0.0}
        };
        {size = {x = width, y = height}, topLeftOffset = topLeftOffset}

    /// ColorRect の表示矩形を計算する。position 原点 = 左上なので offset はゼロ。
    def colorRectRectInfo(rect: ColorRect):
            {size = Vec2.Vec2, topLeftOffset = Vec2.Vec2} =
        let ColorRect.ColorRect(r) = rect;
        {size = r#size, topLeftOffset = {x = 0.0, y = 0.0}}

    /// 1 パス分の EditableEntry を構築する。
    def buildEntry(ctx: LookupCtx, path: NodePath):
            Option[EditableEntry] \ GameEngine.Game =
        forM (
            rootName   <- List.head(path);
            jsonPath   <- Map.get(rootName, ctx#rootJsonIndex);
            engineNode <- Scene.getEngineNode(path, ctx#scene);
            rect       <- rectInfoOf(engineNode)
        ) yield {
            jsonPath = jsonPath,
            nodePath = path,
            width = rect#size#x,
            height = rect#size#y,
            topLeftOffset = rect#topLeftOffset
        }

    /// ノードの表示サイズと topLeftOffset を返す（編集対象でなければ None）。
    def rectInfoOf(engineNode: EngineNode[NodeTag]):
            Option[{size = Vec2.Vec2, topLeftOffset = Vec2.Vec2}] \ GameEngine.Game =
        match engineNode {
            case EngineNode.Sprite2DWithState(sprite, _) => spriteRectInfo(sprite)
            case EngineNode.AnimSprite2DWithState(sprite, _) => animatedSpriteRectInfo(sprite)
            case EngineNode.TextureButtonWithState(btn, _) => Some(buttonRectInfo(btn))
            case EngineNode.Label2DWithState(label, _) => Some(labelRectInfo(label))
            case EngineNode.ColorRectWithState(rect, _) => Some(colorRectRectInfo(rect))
            case _ => None
        }

    /// Sprite2D の矩形情報。
    def spriteRectInfo(sprite: Sprite2D):
            Option[{size = Vec2.Vec2, topLeftOffset = Vec2.Vec2}] \ GameEngine.Game =
        let Sprite2D.Sprite2D(record) = sprite;
        GameEngine.Game.getTextureInfo(record#texture)
            |> Option.map(info -> {
                let size = {x = info#width * record#scale#x,
                            y = info#height * record#scale#y};
                {size = size,
                 topLeftOffset = boxTopLeftOffset(record#centered, size)}
            })

    /// AnimatedSprite2D の矩形情報。
    def animatedSpriteRectInfo(sprite: AnimatedSprite2D):
            Option[{size = Vec2.Vec2, topLeftOffset = Vec2.Vec2}] \ GameEngine.Game =
        let AnimatedSprite2D.AnimatedSprite2D(record) = sprite;
        let texture = AnimatedSprite2D.currentTexture(sprite);
        GameEngine.Game.getTextureInfo(texture)
            |> Option.map(info -> {
                let size = {x = info#width * record#scale#x,
                            y = info#height * record#scale#y};
                {size = size,
                 topLeftOffset = boxTopLeftOffset(record#centered, size)}
            })

    /// TextureButton の矩形情報。
    def buttonRectInfo(btn: TextureButton):
            {size = Vec2.Vec2, topLeftOffset = Vec2.Vec2} =
        let size = TextureButton.getSize(btn);
        {size = size,
         topLeftOffset = boxTopLeftOffset(TextureButton.isCentered(btn), size)}
}
