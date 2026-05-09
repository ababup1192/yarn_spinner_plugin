/// 部屋とホットスポットの静的定義テーブル。
///
/// 設計意図:
///   - 「どの部屋に何のホットスポットがどこにあるか」は実行中に変わらないので、
///     この catalog にハードコードする（後段で scene.json に外出ししても良いが、
///     Phase 1 時点では最小データに留める）
///   - `RoomState.enter(id, hotspots)` を呼ぶときに渡す **初期 hotspot テーブル** は
///     `initialHotspots(roomId)` で生成する。これにより RoomState は catalog を知らず、
///     CommandRouter が両者を仲介する形になる
///   - Phase 1 の段階ではまだクリック判定・描画は実装しないので、座標やサイズは
///     dummy 値（後フェーズで埋める）。`hotspotIds` だけが Phase 1 では意味を持つ
mod Game.RoomCatalog {
    use Game.RoomState.{RoomId, HotspotId, HotspotState, HotspotTable}

    /// 背景テクスチャ名（`bg_<name>` の `<name>` 部分）。
    pub type alias BgTexture = String

    /// ホットスポット 1 個の静的定義。
    /// `position` は design 座標（中心）、`size` は矩形ヒット領域の幅・高さ。
    /// `initiallyLocked` / `initiallyVisible` は部屋入場時のデフォルト状態。
    pub type alias HotspotDef = {
        id                = HotspotId,
        position          = Vec2.Vec2,
        size              = Vec2.Vec2,
        initiallyLocked   = Bool,
        initiallyVisible  = Bool
    }

    /// 部屋 1 つの静的定義。
    pub type alias RoomDef = {
        id        = RoomId,
        bgTexture = BgTexture,
        hotspots  = List[HotspotDef]
    }

    /// 全部屋の id 一覧。`<<room enter <id>>>` のバリデーション用。
    pub def allRoomIds(): List[RoomId] =
        List.map(room -> room#id, allRooms())

    /// 全部屋の定義列。
    pub def allRooms(): List[RoomDef] =
        demoRoom() :: demoRoom2() :: Nil

    /// id から部屋定義を引く。
    pub def find(roomId: RoomId): Option[RoomDef] =
        List.find(room -> room#id == roomId, allRooms())

    /// 部屋入場時に `RoomState.enter` に渡す初期 hotspot テーブルを作る。
    /// 未登録の roomId は空 Map を返す（`RoomState` 側で未登録 id への操作は no-op）。
    pub def initialHotspots(roomId: RoomId): HotspotTable =
        find(roomId)
            |> Option.map(room -> hotspotTableOf(room#hotspots))
            |> Option.getWithDefault(Map.empty())

    /// HotspotDef の List を初期 HotspotTable に畳み込む。
    def hotspotTableOf(defs: List[HotspotDef]): HotspotTable =
        List.foldLeft((acc, hs: HotspotDef) ->
            Map.insert(
                hs#id,
                ({locked = hs#initiallyLocked, visible = hs#initiallyVisible}: HotspotState),
                acc),
            Map.empty(),
            defs)

    // ════════════════════════════════════════════════════════════════════════
    // 静的データ — Phase 2 以降で座標を実値に差し替える
    // ════════════════════════════════════════════════════════════════════════

    /// デモ部屋 1。現代的な「部屋」想定で、引き出し (drawer) と ドア (door) の
    /// 2 ホットスポット。
    ///
    /// design 480×300 (16:10) 上のレイアウト規約:
    ///   - 床ライン y = 224 (床は画面下部 25%、壁は上部 75%)
    ///   - drawer / door の底辺がともに y = 224 に着地して「床に立っている」見た目
    ///   - 左右配置: drawer は左 1/4、door は右 1/4 寄り（中央は通行/カメラ余地）
    def demoRoom(): RoomDef = {
        id        = "demo_room",
        bgTexture = "demo_room",
        hotspots  =
            ({id = "drawer",
              position = ({x = 120.0, y = 200.0}: Vec2.Vec2),
              size     = ({x = 48.0,  y = 48.0}: Vec2.Vec2),
              initiallyLocked  = false,
              initiallyVisible = true}: HotspotDef) ::
            ({id = "door",
              position = ({x = 360.0, y = 176.0}: Vec2.Vec2),
              size     = ({x = 48.0,  y = 96.0}: Vec2.Vec2),
              initiallyLocked  = true,
              initiallyVisible = true}: HotspotDef) ::
            Nil
    }

    /// デモ部屋 2。ドアの先の廊下や別室を想定。Phase 4 で note ノード追加時に拡張する。
    /// note は壁掛けメモを想定して画面中央 (240, 150) に配置。床ラインに着地しない。
    def demoRoom2(): RoomDef = {
        id        = "demo_room2",
        bgTexture = "demo_room2",
        hotspots  =
            ({id = "note",
              position = ({x = 240.0, y = 150.0}: Vec2.Vec2),
              size     = ({x = 64.0,  y = 64.0}: Vec2.Vec2),
              initiallyLocked  = false,
              initiallyVisible = true}: HotspotDef) ::
            Nil
    }
}
