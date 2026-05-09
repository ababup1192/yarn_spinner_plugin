/// `RoomScene` の部屋構築 + Area2D ベースクリック解決の単体テスト。
///
/// scene.json 読み込み（`addRoomLayer`）は I/O 依存なので扱わず、
/// テストでは「Room レイヤだけ手で組み立てた最小 Scene」を入力にする。
/// クリック判定は engine 側 `AreaEvent.dispatchClicks` に流すが、
/// Yarn `Session.start` は handler でモックして「どの yarn ノード名が起動されたか」
/// を Ref に記録 → assertEq で確認する。
///
/// このモジュールが守るべき性質:
///   - `enter` で Data#roomId が更新される
///   - `enter` で catalog の HotspotDef ぶん Area2D 子ノードが並ぶ
///   - `dispatchClicks` が hotspot 矩形内クリックで対応する yarn ノードを起動
///   - 範囲外クリックは何も起動しない
///   - 部屋切替時に旧ホットスポットが消えて、新ホットスポットだけが対象になる
mod TestRoomScene {

    /// テスト中に「Session.start」で起動された yarn ノード名を記録する。
    /// handler が Ref にイベント順で push する。
    type alias StartLog[r: Region] = Ref[List[String], r]

    /// Room レイヤだけを手で積んだ Scene を作る。
    /// scene.json を経由しないので I/O effect 不要。
    /// レイヤは drawLayer = 5 / NodeTag.Room(emptyData) で初期化する。
    def emptySceneWithRoom(): Scene[NodeTag] =
        let layer = CanvasLayer.make(5);
        Scene.empty()
            |> Scene.addNode(
                RoomScene.layerName(),
                EngineNode.CanvasLayerWithState(layer, NodeTag.Room(RoomScene.emptyData())))

    /// `Session.start` だけをログに記録するモック handler。
    /// 他の Session 操作は no-op で握りつぶす。テストは start のみを確認する。
    def withSessionLog(log: StartLog[r], thunk: Unit -> a \ ef):
                        a \ (ef - Dialogue.Session) + r =
        run thunk() with handler Dialogue.Session {
            def start(name, k)              = { Ref.put(name :: Ref.get(log), log); k() }
            def stop(k)                     = k()
            def isActive(k)                 = k(false)
            def submitNext(k)               = k()
            def submitSelect(_idx, k)       = k()
            def submitCommandDone(k)        = k()
            def restart(_node, _vars, k)    = k()
        }

    /// 1 クリックを `dispatchClicks` に流して、そのあとの起動 yarn ノード名を取り出す。
    /// `dispatchClicks` は `AreaHandler.onAreaClicked` 経由で `Session.start` を呼ぶ。
    /// 戻り値はクリックで起動された node 名（複数該当時は preorder の最後＝
    /// Ref に最後に push されたものが head）。
    def clickAndLog(scene: Scene[NodeTag], pos: Vec2.Vec2): List[String] =
        region rc {
            let log: StartLog[rc] = Ref.fresh(rc, Nil);
            withSessionLog(log, () -> {
                discard AreaEvent.dispatchClicks(GameEngine.MouseButton.Left, pos, scene)
            });
            Ref.get(log) |> List.reverse
        }

    // ========================================================================
    // (A) enter: Data#roomId の更新
    // ========================================================================

    /// `enter("demo_room", scene)` のあと layer root の Data#roomId が "demo_room" になる。
    /// `currentRoomId` で取り出して 1 回だけ確認する。
    @Test
    def testEnterUpdatesRoomId(): Unit \ Assert =
        let scene = emptySceneWithRoom()
            |> RoomScene.enter("demo_room");
        Assert.assertEq(expected = "demo_room", RoomScene.currentRoomId(scene))

    // ========================================================================
    // (B) Area2D 配置: catalog ぶん子ノードが並ぶ
    // ========================================================================

    /// `enter("demo_room")` のあと Room レイヤの子に `Hotspot_drawer` と `Hotspot_door` の
    /// Area2D + 兄弟 ColorRect (`HotspotVis_drawer` / `HotspotVis_door`) ぶん 4 ノードが並ぶ。
    /// （scene.json をテストでは読み込まないので Bg は含まれない。
    /// catalog に基づく動的構築だけを確認する。）
    @Test
    def testEnterAddsHotspotChildrenForCatalog(): Unit \ Assert =
        let scene = emptySceneWithRoom()
            |> RoomScene.enter("demo_room");
        let children = List.sort(Scene.getChildrenAt(RoomScene.layerPath(), scene));
        let expected = List.sort(
            "HotspotVis_drawer" :: "HotspotVis_door"
            :: "Hotspot_drawer" :: "Hotspot_door" :: Nil);
        Assert.assertEq(expected = expected, children)

    // ========================================================================
    // (C) クリック → yarn ノード起動
    // ========================================================================

    /// drawer の中心 (120, 200) をクリックすると "Hotspot_demo_room_drawer" が起動する。
    /// engine 側の `dispatchClicks` が Area2D の RectShape2D ヒット判定で
    /// `AreaHandler.onAreaClicked` を発火し、Game.flix の instance が
    /// `Session.start(yarnNodeNameFor(...))` を呼ぶ。
    @Test
    def testClickAtDrawerCenterStartsYarnNode(): Unit \ Assert =
        let scene = emptySceneWithRoom() |> RoomScene.enter("demo_room");
        let started = clickAndLog(scene, ({x = 120.0, y = 200.0}: Vec2.Vec2));
        Assert.assertEq(expected = "Hotspot_demo_room_drawer" :: Nil, started)

    /// door の中心 (360, 176) をクリックすると "Hotspot_demo_room_door" が起動する。
    /// drawer と door が混在する catalog で、別ホットスポットへのヒットも独立に動くこと。
    @Test
    def testClickAtDoorCenterStartsYarnNode(): Unit \ Assert =
        let scene = emptySceneWithRoom() |> RoomScene.enter("demo_room");
        let started = clickAndLog(scene, ({x = 360.0, y = 176.0}: Vec2.Vec2));
        Assert.assertEq(expected = "Hotspot_demo_room_door" :: Nil, started)

    /// catalog 範囲外の点 (10, 10) をクリックしても何も起動しない。
    @Test
    def testClickOutsideAllHotspotsStartsNothing(): Unit \ Assert =
        let scene = emptySceneWithRoom() |> RoomScene.enter("demo_room");
        let started = clickAndLog(scene, ({x = 10.0, y = 10.0}: Vec2.Vec2));
        Assert.assertEq(expected = Nil, started)

    // ========================================================================
    // (D) 矩形端の境界（境界含む）
    // ========================================================================

    /// drawer は中心 (120, 200) / size (48, 48) なので、矩形の左上端 (96, 176) と
    /// 右下端 (144, 224) はぎりぎりヒット領域に含まれる（CollisionShape2D.containsPoint
    /// は境界を含む実装）。直前 (95, 175) と直後 (145, 225) は外。
    @Test
    def testHotspotBoundaryEdges(): Unit \ Assert =
        let scene = emptySceneWithRoom() |> RoomScene.enter("demo_room");
        let topLeft     = clickAndLog(scene, ({x = 96.0,  y = 176.0}: Vec2.Vec2));
        let bottomRight = clickAndLog(scene, ({x = 144.0, y = 224.0}: Vec2.Vec2));
        let outsideTL   = clickAndLog(scene, ({x = 95.0,  y = 175.0}: Vec2.Vec2));
        let outsideBR   = clickAndLog(scene, ({x = 145.0, y = 225.0}: Vec2.Vec2));
        let drawer = "Hotspot_demo_room_drawer" :: Nil;
        Assert.assertEq(expected = (drawer, drawer, Nil, Nil),
                         (topLeft, bottomRight, outsideTL, outsideBR))

    // ========================================================================
    // (E) 部屋切替: 旧ホットスポットは消える
    // ========================================================================

    /// `enter("demo_room")` で drawer をヒットできていた状態から、
    /// `enter("demo_room2")` に切り替えると drawer 中心をクリックしても何も起動しない。
    /// catalog 上 demo_room2 にあるのは note (中心 240,150) だけなので、drawer 座標は無効。
    @Test
    def testRoomSwitchInvalidatesPreviousHotspots(): Unit \ Assert =
        let scene1 = emptySceneWithRoom() |> RoomScene.enter("demo_room");
        let hitDrawer = clickAndLog(scene1, ({x = 120.0, y = 200.0}: Vec2.Vec2));
        let scene2 = scene1 |> RoomScene.enter("demo_room2");
        let missDrawer = clickAndLog(scene2, ({x = 120.0, y = 200.0}: Vec2.Vec2));
        let hitNote    = clickAndLog(scene2, ({x = 240.0, y = 150.0}: Vec2.Vec2));
        Assert.assertEq(
            expected = ("Hotspot_demo_room_drawer" :: Nil,
                        Nil,
                        "Hotspot_demo_room2_note" :: Nil),
            (hitDrawer, missDrawer, hitNote))
}
