// DragInput — マウス入力 → 選択 → ドラッグ → 書き戻し のディスパッチ
//
// 押下／継続／離脱 のフレーム判定を `EditorStateData#prevMouseLeft` のエッジから行い、
// 編集対象ノードへの選択 / 移動 / リサイズ / JSON 書き戻し に振り分ける。
// 押下したがそのまま離した（クリック選択のみ）場合は位置が変わっていないので
// ファイル書き込みをスキップする（mtime 更新で HotReload を無駄打ちさせない）。

mod DragInput {

    /// 1 フレーム分のマウス状態スナップ（位置 + 左ボタン押下中かどうか）。
    pub type alias MouseSnapshot = {
        pos = Vec2.Vec2,
        leftDown = Bool
    }

    /// マウスの押下／継続／離脱を判定し、選択 / ドラッグ更新 / リサイズ / 書き戻し を
    /// ディスパッチする。
    pub def handleMouse(mouse: MouseSnapshot,
                        transform: Camera2D.ViewTransform,
                        stateData: Editor.EditorStateData,
                        scene: Scene[NodeTag]):
            (Editor.EditorStateData, Scene[NodeTag]) \
            {EditHistory.Rewind, GameEngine.Game, Fs.FileRead, Fs.FileWrite} =
        let prevLeft = stateData#prevMouseLeft;
        let pressedNow = mouse#leftDown and not prevLeft;
        let releasedNow = (not mouse#leftDown) and prevLeft;
        if (pressedNow) {
            handleMouseDown(mouse#pos, transform, stateData, scene)
        } else if (mouse#leftDown and Option.nonEmpty(stateData#resizeOrigin)) {
            (stateData, applyResize(mouse#pos, stateData, scene))
        } else if (mouse#leftDown and Option.nonEmpty(stateData#dragOrigin)) {
            (stateData, applyDrag(mouse#pos, stateData, scene))
        } else if (releasedNow and Option.nonEmpty(stateData#resizeOrigin)) {
            saveResizedNode(stateData, scene)
        } else if (releasedNow and Option.nonEmpty(stateData#dragOrigin)) {
            saveDraggedPos(stateData, scene)
        } else {
            (stateData, scene)
        }

    /// ドラッグ中: マウスの移動量に応じてノードのグローバル位置を更新する。
    /// ピクセル単位に整数スナップして「カクカク」動かす
    pub def applyDrag(mousePos: Vec2.Vec2, stateData: Editor.EditorStateData,
                      scene: Scene[NodeTag]): Scene[NodeTag] =
        match (stateData#selected, stateData#dragOrigin, stateData#nodeOrigin) {
            case (Some((_, nodePath)), Some(dragOrigin), Some(nodeOrigin)) =>
                let delta = Vec2.sub(mousePos, dragOrigin);
                let newGlobalPos = snapVec2(Vec2.add(nodeOrigin, delta));
                Scene.setGlobalPositionAt(nodePath, newGlobalPos, scene)
            case _ => scene
        }

    /// リサイズ中: マウス移動量から新しい bbox を計算し、scale と position を更新する。
    pub def applyResize(mousePos: Vec2.Vec2, stateData: Editor.EditorStateData,
                        scene: Scene[NodeTag]): Scene[NodeTag] =
        match (stateData#selected, stateData#dragOrigin, stateData#resizeOrigin) {
            case (Some((_, nodePath)), Some(dragOrigin), Some(origin)) =>
                let delta = Vec2.sub(mousePos, dragOrigin);
                let originalBox = {topLeft = origin#boxTopLeftScreen,
                                   size = origin#boxSize};
                let newBox = ResizeHandle.applyDrag(origin#handle,
                    originalBox, delta, minDisplaySize());
                let scaleRatio = {x = safeRatio(newBox#size#x, origin#boxSize#x),
                                  y = safeRatio(newBox#size#y, origin#boxSize#y)};
                let newScale = {x = origin#scale#x * scaleRatio#x,
                                y = origin#scale#y * scaleRatio#y};
                let newOffset = scaleTopLeftOffset(origin#topLeftOffset,
                                                    origin#boxSize, newBox#size);
                let newWorldPos = snapVec2(Vec2.sub(newBox#topLeft, newOffset));
                scene
                    |> Scene.mapEngineNode(nodePath, Node2D.setScale(newScale))
                    |> Scene.setGlobalPositionAt(nodePath, newWorldPos)
            case _ => scene
        }

    def minDisplaySize(): Vec2.Vec2 = {x = 1.0, y = 1.0}

    def safeRatio(newSize: Float64, originalSize: Float64): Float64 =
        if (originalSize == 0.0) 1.0 else newSize / originalSize

    def scaleTopLeftOffset(originalOffset: Vec2.Vec2,
                           originalSize: Vec2.Vec2,
                           newSize: Vec2.Vec2): Vec2.Vec2 =
        {x = originalOffset#x * safeRatio(newSize#x, originalSize#x),
         y = originalOffset#y * safeRatio(newSize#y, originalSize#y)}

    pub def snapVec2(v: Vec2.Vec2): Vec2.Vec2 =
        {x = Float64.round(v#x), y = Float64.round(v#y)}

    /// クリック押下時: まず選択中ノードのリサイズハンドルに hit したかを判定し、
    /// hit していればリサイズドラッグを開始する。外していれば従来どおり編集対象ノードを
    /// pickTopAt で掴んで移動ドラッグを開始する。
    /// Shift を押しながらクリックすると、コンテナ優先ピックを切って z-index 最大の
    /// 子要素を直接掴める（ダイアログ内の個別 ColorRect を微調整したいとき用）。
    def handleMouseDown(mousePos: Vec2.Vec2, transform: Camera2D.ViewTransform,
                        stateData: Editor.EditorStateData,
                        scene: Scene[NodeTag]):
            (Editor.EditorStateData, Scene[NodeTag]) \ GameEngine.Game =
        match tryStartResize(mousePos, transform, stateData, scene) {
            case Some(newState) => (newState, scene)
            case None =>
                let ctx = {rootJsonIndex = stateData#rootJsonIndex, scene = scene};
                let entries = EditableNode.collectAll(ctx);
                let preferDescendant = GameEngine.Game.isKeyPressed(GameEngine.Key.LeftShift);
                let hit = Picking.pickTopAt(mousePos, entries, transform, preferDescendant, scene);
                match hit {
                    case None =>
                        ({selected = None, dragOrigin = None, nodeOrigin = None,
                          resizeOrigin = None | stateData}, scene)
                    case Some((entry, _)) =>
                        let nodeWorld = Scene.globalPositionAt(entry#nodePath, scene);
                        let newState = {
                            selected = Some((entry#jsonPath, entry#nodePath)),
                            dragOrigin = Some(mousePos),
                            nodeOrigin = Some(nodeWorld),
                            resizeOrigin = None
                            | stateData
                        };
                        (newState, scene)
                }
        }

    /// 選択中ノードがあり、マウスがそのリサイズハンドル領域内にあるかを判定する。
    def tryStartResize(mousePos: Vec2.Vec2, transform: Camera2D.ViewTransform,
                       stateData: Editor.EditorStateData,
                       scene: Scene[NodeTag]):
            Option[Editor.EditorStateData] \ GameEngine.Game =
        match stateData#selected {
            case None => None
            case Some((_, nodePath)) =>
                let ctx = {rootJsonIndex = stateData#rootJsonIndex, scene = scene};
                match EditableNode.findByNodePath(ctx, nodePath) {
                    case None => None
                    case Some(entry) =>
                        let refPos = Scene.screenPositionAt(nodePath, transform, scene);
                        let topLeft = Vec2.add(refPos, entry#topLeftOffset);
                        let box = {topLeft = topLeft,
                                   size = {x = entry#width, y = entry#height}};
                        match ResizeHandle.hitTest(mousePos, box) {
                            case None => None
                            case Some(handle) =>
                                let nodeWorld = Scene.globalPositionAt(nodePath, scene);
                                let nodeScale = match Scene.getEngineNode(nodePath, scene) {
                                    case Some(engineNode) => Node2D.getScale(engineNode)
                                    case None             => {x = 1.0, y = 1.0}
                                };
                                let resizeOrigin: Editor.ResizeOrigin = {
                                    handle = handle,
                                    boxTopLeftScreen = topLeft,
                                    boxSize = {x = entry#width, y = entry#height},
                                    scale = nodeScale,
                                    worldPos = nodeWorld,
                                    topLeftOffset = entry#topLeftOffset
                                };
                                Some({
                                    dragOrigin = Some(mousePos),
                                    nodeOrigin = Some(nodeWorld),
                                    resizeOrigin = Some(resizeOrigin)
                                    | stateData
                                })
                        }
                }
        }

    /// ドロップ: 現在のシーン上のノード位置を JSON に書き戻し、ドラッグ状態を解除する。
    def saveDraggedPos(stateData: Editor.EditorStateData,
                       scene: Scene[NodeTag]):
            (Editor.EditorStateData, Scene[NodeTag]) \
            {EditHistory.Rewind, Fs.FileRead, Fs.FileWrite} =
        match stateData#selected {
            case Some((jsonPath, nodePath)) =>
                let currentGlobal = Scene.globalPositionAt(nodePath, scene);
                let moved = match stateData#nodeOrigin {
                    case Some(origin) =>
                        currentGlobal#x != origin#x or currentGlobal#y != origin#y
                    case None => false
                };
                if (moved) {
                    match stateData#nodeOrigin {
                        case Some(origin) =>
                            EditHistory.Rewind.save(EditHistory.Entry.MoveEntry({
                                jsonPath = jsonPath,
                                nodePath = nodePath,
                                prevWorldPos = origin}))
                        case None => ()
                    };
                    let localPos = match Scene.getEngineNode(nodePath, scene) {
                        case Some(engineNode) => Node2D.getPosition(engineNode)
                        case None => Vec2.zero()
                    };
                    SceneSerializer.updatePos(jsonPath, nodePath, localPos)
                } else ();
                let cleared = {
                    dragOrigin = None,
                    nodeOrigin = None
                    | stateData
                };
                (cleared, scene)
            case None => (stateData, scene)
        }

    /// リサイズドロップ: scale と pos の両方を JSON に書き戻し、リサイズ状態を解除する。
    def saveResizedNode(stateData: Editor.EditorStateData,
                        scene: Scene[NodeTag]):
            (Editor.EditorStateData, Scene[NodeTag]) \
            {EditHistory.Rewind, Fs.FileRead, Fs.FileWrite} =
        match (stateData#selected, stateData#resizeOrigin) {
            case (Some((jsonPath, nodePath)), Some(origin)) =>
                let currentScale = match Scene.getEngineNode(nodePath, scene) {
                    case Some(engineNode) => Node2D.getScale(engineNode)
                    case None             => origin#scale
                };
                let currentGlobal = Scene.globalPositionAt(nodePath, scene);
                let scaleChanged = currentScale#x != origin#scale#x or
                                   currentScale#y != origin#scale#y;
                let posChanged = currentGlobal#x != origin#worldPos#x or
                                 currentGlobal#y != origin#worldPos#y;
                if (scaleChanged or posChanged) {
                    EditHistory.Rewind.save(EditHistory.Entry.ScaleEntry({
                        jsonPath = jsonPath,
                        nodePath = nodePath,
                        prevWorldPos = origin#worldPos,
                        prevScale = origin#scale}));
                    let localPos = match Scene.getEngineNode(nodePath, scene) {
                        case Some(engineNode) => Node2D.getPosition(engineNode)
                        case None => Vec2.zero()
                    };
                    SceneSerializer.updatePosAndScale(jsonPath, nodePath, localPos,
                                                       currentScale)
                } else ();
                let cleared = {
                    dragOrigin = None,
                    nodeOrigin = None,
                    resizeOrigin = None
                    | stateData
                };
                (cleared, scene)
            case _ => (stateData, scene)
        }
}
