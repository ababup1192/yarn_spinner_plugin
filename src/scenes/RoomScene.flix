/// 部屋の背景 + クリック可能ホットスポット（Area2D）を 1 枚の CanvasLayer にまとめる Scene 層。
///
/// 設計意図:
///   - レイヤ root が `NodeTag.Room(Data)` を持ち、`Data#roomId` で
///     「いま何の部屋を表示しているか」を保持する
///   - 背景 Sprite2D は scene.json で 1 枚定義しておき、`enter` でテクスチャを差し替える
///   - ホットスポットは `<<room enter>>` のたびに `RoomCatalog` から動的に
///     **Area2D + 兄弟 ColorRect** のペアとして構築し直す。Phase 2 ではデバッグ用に
///     半透明の色付き矩形（ColorRect）で見た目を出し、クリック判定は Area2D の
///     `CollisionShape2D.RectShape2D` が担当する
///   - クリックイベントは `Game.flix` の `InputHandler.onMouseButtonPressed` から
///     `AreaEvent.dispatchClicks` に流れ、`AreaHandler.onAreaClicked` に届く。
///     ヒットした Area2D の `NodeTag.Hotspot(data)` から yarn ノード名を組み立てて
///     `Dialogue.Session.start` を発火する
///
/// レイヤ構成:
///   CanvasLayer "Room" (drawLayer = 5、Background=0 と Dialogue=10 の間)
///     ├── Sprite2D "Bg"             — 部屋背景 (テクスチャは catalog から `enter` で注入)
///     ├── Area2D "Hotspot_<id>"     — クリック対象 (NodeTag.Hotspot)
///     ├── ColorRect "HotspotVis_<id>" — Phase 2 デバッグ表示
///     ├── Area2D "Hotspot_<id>" ...
///     └── ColorRect "HotspotVis_<id>" ...
mod RoomScene {
    use Game.RoomState.{RoomId, HotspotId}
    use Game.RoomCatalog.{RoomDef, HotspotDef}

    // ════════════════════════════════════════════════════════════════════════
    // (A) 型定義 — NodeTag に乗せる Data
    // ════════════════════════════════════════════════════════════════════════

    /// 現在表示中の部屋 id。空文字は「未入場」（addRoomLayer 直後の状態）。
    pub type alias Data = { roomId = RoomId }

    /// `NodeTag.Hotspot` に乗せる「どの部屋のどのホットスポットか」。
    /// click 時に yarn ノード名を組み立てるための識別情報。
    pub type alias HotspotData = { roomId = RoomId, hotspotId = HotspotId }

    /// `NodeTag.Room` の初期値（未入場）。
    pub def emptyData(): Data = ({roomId = ""}: Data)

    // ════════════════════════════════════════════════════════════════════════
    // (B) 定数 — ノード名・パス・配置・色
    // ════════════════════════════════════════════════════════════════════════

    /// レイヤノード名（scene.json と一致させる）。
    pub def layerName(): String = "Room"

    /// レイヤ root への NodePath。
    pub def layerPath(): NodePath = layerName() :: Nil

    /// 背景 Sprite2D の名前（scene.json と一致）。
    def bgName(): String = "Bg"

    /// 背景 Sprite2D への NodePath。
    def bgPath(): NodePath = layerName() :: bgName() :: Nil

    /// ホットスポット Area2D のノード名 prefix。
    /// 子ノード `Hotspot_<hotspotId>` を catalog 由来の id で識別する。
    def areaNamePrefix(): String = "Hotspot_"

    /// デバッグ視覚 (ColorRect) のノード名 prefix。`Hotspot_` と区別する。
    def visNamePrefix(): String = "HotspotVis_"

    /// Area2D ノード名生成。
    def areaNodeName(id: HotspotId): String = areaNamePrefix() + id

    /// 視覚 ColorRect ノード名生成。
    def visNodeName(id: HotspotId): String = visNamePrefix() + id

    /// 背景テクスチャ名生成（catalog の `bgTexture` に prefix `bg_` を付ける）。
    /// 例: `bgTexture = "demo_room"` → `"bg_demo_room"`。
    def bgTextureName(bgTexture: String): String = "bg_" + bgTexture

    /// ホットスポット視覚用 Sprite2D のテクスチャ名生成。
    /// 例: `hotspotId = "drawer"` → `"sprite_drawer"`。Main.flix の textureManifest と
    /// `scripts/process-sprites.sh` の出力ファイル名 (`sprite_<id>.png`) と揃える。
    def hotspotTextureName(hotspotId: HotspotId): String = "sprite_" + hotspotId

    /// scene.json のパス。
    def sceneJsonPath(): String = "src/scenes/RoomScene.scene.json"

    // ════════════════════════════════════════════════════════════════════════
    // (C) 構築 — addRoomLayer
    // ════════════════════════════════════════════════════════════════════════

    /// scene.json をロードしてレイヤを 1 枚積む。Root に `NodeTag.Room(emptyData())`
    /// を載せて、後続の `enter` でホットスポットや背景テクスチャを差し替える。
    pub def addRoomLayer(scene: Scene[NodeTag]):
                          Scene[NodeTag] \ {GameEngine.Game, Fs.FileRead} =
        SceneLoader.loadScene(sceneJsonPath(),
                              SceneLoader.constTagParser(NodeTag.NoTag),
                              scene)
            |> Scene.setState(layerPath(), NodeTag.Room(emptyData()))

    // ════════════════════════════════════════════════════════════════════════
    // (D) ロジック — enter / yarnNodeNameFor
    // ════════════════════════════════════════════════════════════════════════

    /// `<<room enter <id>>>` の効果を Scene に適用する。
    ///   1. レイヤ root の Data#roomId を更新
    ///   2. 背景 Sprite2D のテクスチャを catalog の `bgTexture` に切替え（visible=true）
    ///   3. 既存のホットスポット (Area2D + 兄弟 ColorRect) 子をすべて取り除き、
    ///      catalog の HotspotDef から新規構築
    ///
    /// 未登録の roomId の場合は背景を invisible、hotspots は無しで「空っぽ部屋」
    /// に整合させる（yarn 側のタイプミスで panic させない）。
    pub def enter(roomId: RoomId, scene: Scene[NodeTag]): Scene[NodeTag] =
        scene
            |> Scene.setState(layerPath(), NodeTag.Room(({roomId = roomId}: Data)))
            |> applyBackground(roomId)
            |> rebuildHotspots(roomId)

    /// 部屋の背景テクスチャを catalog から引いて Sprite2D に反映する。
    /// 未登録 roomId は visible=false にして「何も描かない」状態にする。
    def applyBackground(roomId: RoomId, scene: Scene[NodeTag]): Scene[NodeTag] =
        match Game.RoomCatalog.find(roomId) {
            case None       => mapBackgroundSprite(s -> CanvasItem.setVisible(false, s), scene)
            case Some(room) =>
                let textureName = bgTextureName(room#bgTexture);
                mapBackgroundSprite(s ->
                    s |> Sprite2D.setTexture(textureName)
                      |> CanvasItem.setVisible(true), scene)
        }

    /// 既存ホットスポット子（Area2D / 兄弟 ColorRect）を全削除し、
    /// catalog の HotspotDef から作り直す。未登録 roomId なら削除のみ。
    def rebuildHotspots(roomId: RoomId, scene: Scene[NodeTag]): Scene[NodeTag] =
        let cleared = removeAllHotspotChildren(scene);
        match Game.RoomCatalog.find(roomId) {
            case None       => cleared
            case Some(room) =>
                List.foldLeft((sc, hs: HotspotDef) -> addHotspotPair(roomId, hs, sc),
                              cleared, room#hotspots)
        }

    /// 子ノード一覧から `Hotspot_` / `HotspotVis_` 始まりのものを順に外す。
    /// 既存 catalog から消えた id にも追従できる。
    def removeAllHotspotChildren(scene: Scene[NodeTag]): Scene[NodeTag] =
        let isHotspotChild = name ->
            String.startsWith({prefix = areaNamePrefix()}, name)
            or String.startsWith({prefix = visNamePrefix()}, name);
        let hotspotChildren =
            Scene.getChildrenAt(layerPath(), scene)
                |> List.filter(isHotspotChild);
        List.foldLeft((sc, name) ->
            Scene.removeAt(layerName() :: name :: Nil, sc),
            scene,
            hotspotChildren)

    /// 1 ホットスポット分のペア（Area2D + 兄弟 ColorRect）を Room レイヤ直下に追加する。
    /// Area2D に `NodeTag.Hotspot(data)` をタグ付けし、AreaHandler.onAreaClicked が
    /// `data#roomId` / `data#hotspotId` を読んで yarn ノードを起動できるようにする。
    /// ColorRect はクリック判定には絡まず、見た目だけ。
    def addHotspotPair(roomId: RoomId, hs: HotspotDef,
                        scene: Scene[NodeTag]): Scene[NodeTag] =
        scene
            |> addHotspotArea(roomId, hs)
            |> addHotspotVisual(hs)

    /// Area2D を 1 個追加する。`monitoring=true` で初期化し、
    /// CollisionShape2D.RectShape2D に catalog の size を入れる。
    /// `position` は catalog の中心座標をそのまま使う（Area2D の position は中心）。
    def addHotspotArea(roomId: RoomId, hs: HotspotDef,
                        scene: Scene[NodeTag]): Scene[NodeTag] =
        let shape = CollisionShape2D.RectShape2D({
            width = hs#size#x,
            height = hs#size#y
        });
        let area = Area2D.make(hs#position, shape);
        let data = ({roomId = roomId, hotspotId = hs#id}: HotspotData);
        Scene.addChild(
            layerName(),
            areaNodeName(hs#id),
            EngineNode.Area2DWithState(area, NodeTag.Hotspot(data)),
            scene)

    /// 兄弟 Sprite2D を 1 個追加する。テクスチャ名は `sprite_<hotspotId>` 規約で
    /// 解決し、scale=(1,1) でそのまま catalog 設定の design size と一致させる。
    /// Sprite2D は centered=true がデフォルトなので、catalog の中心座標 hs#position を
    /// そのまま position に渡せば左右上下が揃う。
    ///
    /// zIndex は明示的に `hotspotZIndex()` (=1) にして、scene.json の Bg sprite
    /// (zIndex 未指定 = 0) より必ず手前に描画されるよう保証する。
    /// `List.sortBy` は不安定 (Quicksort) なので同 z のときに sort 結果で順序が
    /// 偶然変わり、Bg が hotspot を覆ってしまうのを避ける。
    def addHotspotVisual(hs: HotspotDef, scene: Scene[NodeTag]): Scene[NodeTag] =
        let texName = hotspotTextureName(hs#id);
        let sprite = Sprite2D.make(texName, hs#position, ({x = 1.0, y = 1.0}: Vec2.Vec2))
            |> CanvasItem.setZIndex(hotspotZIndex());
        Scene.addChild(
            layerName(),
            visNodeName(hs#id),
            EngineNode.Sprite2DWithState(sprite, NodeTag.NoTag),
            scene)

    /// ホットスポット視覚 Sprite2D の zIndex。`Bg` は 0 なので 1 で常に手前。
    /// dialogue layer (drawLayer=10) より下なので対話パネルは引き続き上に来る。
    def hotspotZIndex(): Int32 = 1

    /// レイヤ root の `Data#roomId` を取り出す（未入場時は空文字）。
    pub def currentRoomId(scene: Scene[NodeTag]): RoomId =
        match Scene.getState(layerPath(), scene) {
            case Some(NodeTag.Room(data)) => data#roomId
            case _                        => ""
        }

    /// 背景 Sprite2D を変換するボイラプレート。
    def mapBackgroundSprite(f: Sprite2D -> Sprite2D, scene: Scene[NodeTag]): Scene[NodeTag] =
        Scene.mapEngineNode(bgPath(), engineNode ->
            EngineNode.mapSprite2D(f, engineNode),
            scene)

    /// クリック解決の命名規約。`Hotspot_<roomId>_<hotspotId>`。
    /// `AreaHandler.onAreaClicked` が `HotspotData` から組み立てて `Session.start` に渡す。
    /// Yarn 側はこの規約のノードを定義してクリックを受ける。
    pub def yarnNodeNameFor(roomId: RoomId, hotspotId: HotspotId): String =
        areaNamePrefix() + roomId + "_" + hotspotId
}
