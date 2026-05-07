/// Editor — F1 キーでトグルするビジュアルエディタの ON/OFF 管理
///
/// Tween.withScheduler(rc) と同じ effect handler パターンで実装。
/// `Game.start` で `with Editor.withState(rc)` を 1 行注入し、
/// `gameLoop` の先頭で `Editor.handleInput(scene)` を呼ぶ。
///
/// 責務:
///   - F1 キーのエッジ検出（押し続けで連打されない）
///   - ON/OFF 状態の保持
///   - HotReload チャネルの非ブロッキング受信の中継

mod Editor {

    /// エディタの ON/OFF 状態と入力・リロード判定を提供する effect。
    pub eff State {
        /// F1 エッジ検出 + トグル。毎フレーム先頭で 1 回呼ぶ。
        def handleInput(): Unit
        /// 現在の ON/OFF を返す。
        def isOn(): Bool
        /// HotReload チャネルの非ブロッキング受信。true ならリロード要求あり。
        def pollReload(): Bool
    }

    /// handler 注入。Tween.withScheduler(rc) と同じ流儀。
    /// `onRef` / `prevF1Ref` は closure に閉じ込められ外には漏れない。
    /// `reloadRx` は初期化時に HotReload.startWatcher() で watcher スレッドを起動し、
    /// 以降は pollReload で非ブロッキング受信するだけ。
    pub def withState(rc: Region[r]):
            (Unit -> a \ ef) -> a
            \ (ef - State) + {r, GameEngine.Game, Chan, NonDet, IO,
                               Fs.Glob, Fs.ModificationTime} =
        thunk -> {
            let onRef     = Ref.fresh(rc, false);
            let prevF1Ref = Ref.fresh(rc, false);
            let reloadRx  = HotReload.startWatcher();
            run { thunk() }
            with handler State {
                def handleInput(k) = {
                    let curr = GameEngine.Game.isKeyPressed(GameEngine.Key.F1);
                    let prev = Ref.get(prevF1Ref);
                    Ref.put(curr, prevF1Ref);
                    if (curr and not prev)
                        Ref.put(not Ref.get(onRef), onRef)
                    else ();
                    k()
                }
                def isOn(k) = k(Ref.get(onRef))
                def pollReload(k) = k(HotReload.pollReload(reloadRx))
            }
        }

    /// F1 エッジ検出を行い、scene をそのまま返す。gameLoop パイプラインの先頭で呼ぶ。
    pub def handleInput(scene: Scene[s]): Scene[s] \ State =
        State.handleInput();
        scene

    /// エディタが ON なら true。
    pub def isOn(): Bool \ State = State.isOn()

    /// HotReload チャネルにリロード要求が来ていれば true。
    pub def pollReload(): Bool \ State = State.pollReload()

    /// エディタ ON のときだけ "[EDITOR]" ラベルを前面レイヤに載せた Scene を返す。
    /// 描画にだけ使われ、次フレームの gameLoop には元の scene が渡る。
    /// `emptyTag` を受け取ることで NodeTag に依存せずジェネリックに保つ。
    pub def applyOverlay(fontAtlas: FontAtlas, emptyTag: s, scene: Scene[s]):
            Scene[s] \ State =
        if (not State.isOn()) scene
        else
            let layer = CanvasLayer.make(99);
            let label = Label2D.make("[EDITOR]", fontAtlas, fontAtlas#fontSize)
                |> Node2D.setPosition({x = 4.0, y = 4.0})
                |> CanvasItem.setModulate({r = 1.0f32, g = 0.9f32, b = 0.2f32});
            scene
                |> Scene.addNode("EditorOverlay",
                    EngineNode.CanvasLayerWithState(layer, emptyTag))
                |> Scene.addChild("EditorOverlay", "Label",
                    EngineNode.Label2DWithState(label, emptyTag))
}
