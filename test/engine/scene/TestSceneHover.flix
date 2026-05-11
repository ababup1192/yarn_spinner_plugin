/// `Scene.getGlobalRect` と `Scene.hoveredPathsAt` のユニットテスト。
///
/// hover イベント (`InputEvent.onMouseEntered/Exited/Hover`) のヒット判定基盤。
/// `EngineNode.getSize` を持つ可視ノードのみが hover 対象になり、
/// 不可視サブツリー（CanvasLayer.visible=false 等）は丸ごとスキップされる。
mod TestSceneHover {

    /// テスト用状態: 追加データなしの最小構成。
    enum HState with Eq, Order, ToString {
        case HState
    }

    instance Node[HState] {
        type Aef = {}
    }

    /// 指定位置・サイズの Control ノード（top-left 配置）を作る。
    def hcontrol(x: Float64, y: Float64, w: Float64, h: Float64): EngineNode[HState] =
        let size: Vec2.Vec2 = {x = w, y = h};
        let pos: Vec2.Vec2 = {x = x, y = y};
        let ctrl = Control.make(size) |> Node2D.setPosition(pos);
        EngineNode.ControlWithState(ctrl, HState.HState)

    /// 指定位置の CanvasLayer ノードを作る（drawLayer=0）。
    def hlayer(x: Float64, y: Float64): EngineNode[HState] =
        let pos: Vec2.Vec2 = {x = x, y = y};
        let cl = CanvasLayer.make(0) |> Node2D.setPosition(pos);
        EngineNode.CanvasLayerWithState(cl, HState.HState)

    /// 不可視 CanvasLayer。
    def hlayerInvisible(x: Float64, y: Float64): EngineNode[HState] =
        let pos: Vec2.Vec2 = {x = x, y = y};
        let cl = CanvasLayer.make(0)
                     |> Node2D.setPosition(pos)
                     |> CanvasItem.setVisible(false);
        EngineNode.CanvasLayerWithState(cl, HState.HState)

    /// サイズを持たないノード（Marker2D）。`getSize` は None。
    def hmarker(x: Float64, y: Float64): EngineNode[HState] =
        let pos: Vec2.Vec2 = {x = x, y = y};
        EngineNode.Marker2DWithState(Marker2D.make(pos), HState.HState)

    // ========================================================================
    // getGlobalRect
    // ========================================================================

    /// ルート直下の Control の global rect は (position, size) そのまま。
    @Test
    def testGetGlobalRectRootControl(): Unit \ Assert =
        let scene: Scene[HState] = Scene.empty()
            |> Scene.addNode("box", hcontrol(10.0, 20.0, 30.0, 40.0));
        let rectOpt = Scene.getGlobalRect("box" :: Nil, scene);
        match rectOpt {
            case Some(rect) =>
                Assert.assertEq(expected = (10.0, 20.0, 30.0, 40.0),
                    (rect#position#x, rect#position#y, rect#size#x, rect#size#y))
            case None => Assert.assertEq(expected = "Some(rect)", "None")
        }

    /// CanvasLayer の中の Control は layer.position + control.position が global pos。
    @Test
    def testGetGlobalRectNestedUnderCanvasLayer(): Unit \ Assert =
        let scene: Scene[HState] = Scene.empty()
            |> Scene.addNode("layer", hlayer(16.0, 216.0))
            |> Scene.addChild("layer", "body", hcontrol(9.0, 9.0, 430.0, 54.0));
        let rectOpt = Scene.getGlobalRect("layer" :: "body" :: Nil, scene);
        match rectOpt {
            case Some(rect) =>
                Assert.assertEq(expected = (25.0, 225.0, 430.0, 54.0),
                    (rect#position#x, rect#position#y, rect#size#x, rect#size#y))
            case None => Assert.assertEq(expected = "Some(rect)", "None")
        }

    /// `size` を持たない Marker2D は None。
    @Test
    def testGetGlobalRectNoSize(): Unit \ Assert =
        let scene: Scene[HState] = Scene.empty()
            |> Scene.addNode("m", hmarker(10.0, 20.0));
        Assert.assertEq(expected = false,
            Option.nonEmpty(Scene.getGlobalRect("m" :: Nil, scene)))

    /// 存在しないパスも None。
    @Test
    def testGetGlobalRectMissingPath(): Unit \ Assert =
        let scene: Scene[HState] = Scene.empty();
        Assert.assertEq(expected = false,
            Option.nonEmpty(Scene.getGlobalRect("ghost" :: Nil, scene)))

    // ========================================================================
    // hoveredPathsAt
    // ========================================================================

    /// 点が Control の bounds 内 → そのパスを含む。
    @Test
    def testHoveredPathsAtInside(): Unit \ Assert =
        let scene: Scene[HState] = Scene.empty()
            |> Scene.addNode("box", hcontrol(10.0, 20.0, 30.0, 40.0));
        let point: Vec2.Vec2 = {x = 25.0, y = 30.0};
        let result = Scene.hoveredPathsAt(point, scene);
        Assert.assertEq(expected = (1, true),
            (Set.size(result), Set.memberOf("box" :: Nil, result)))

    /// 点が外側 → 空セット。
    @Test
    def testHoveredPathsAtOutside(): Unit \ Assert =
        let scene: Scene[HState] = Scene.empty()
            |> Scene.addNode("box", hcontrol(10.0, 20.0, 30.0, 40.0));
        let point: Vec2.Vec2 = {x = 100.0, y = 100.0};
        let result = Scene.hoveredPathsAt(point, scene);
        Assert.assertEq(expected = 0, Set.size(result))

    /// 親 CanvasLayer が invisible なら、子 Control が点上にあってもヒットしない
    /// （サブツリーごとスキップ）。
    @Test
    def testHoveredPathsAtSkipsInvisibleSubtree(): Unit \ Assert =
        let scene: Scene[HState] = Scene.empty()
            |> Scene.addNode("layer", hlayerInvisible(0.0, 0.0))
            |> Scene.addChild("layer", "body", hcontrol(0.0, 0.0, 100.0, 100.0));
        let point: Vec2.Vec2 = {x = 50.0, y = 50.0};
        let result = Scene.hoveredPathsAt(point, scene);
        Assert.assertEq(expected = 0, Set.size(result))

    /// 同じ点に乗っている複数の Control はすべて含まれる。
    /// （重なった ColorRect/RichTextLabel を想定。topmost 絞り込みは handler 側の責務）
    @Test
    def testHoveredPathsAtIncludesAllStacked(): Unit \ Assert =
        let scene: Scene[HState] = Scene.empty()
            |> Scene.addNode("layer", hlayer(0.0, 0.0))
            |> Scene.addChild("layer", "border", hcontrol(0.0, 0.0, 50.0, 50.0))
            |> Scene.addChild("layer", "body", hcontrol(0.0, 0.0, 50.0, 50.0));
        let point: Vec2.Vec2 = {x = 25.0, y = 25.0};
        let result = Scene.hoveredPathsAt(point, scene);
        // border と body の両方を含む（layer は size なしで除外）
        Assert.assertEq(expected = (2, true, true),
            (Set.size(result),
             Set.memberOf("layer" :: "border" :: Nil, result),
             Set.memberOf("layer" :: "body" :: Nil, result)))
}
