/// Dialogue 層の effect・型・純粋遷移を集約するモジュール。
///
/// 提供するもの:
///
///   - 3 つの effect: `Session` / `DialogueView` / `CommandRegistry`
///   - view 用の整形済み型: `PresentedLine` / `PresentedOption`
///   - 1 フレーム単位で受け渡す view イベント: `ViewEvent`
///   - 対話 UI の論理状態: `UIState` と、その純粋遷移（`applyEvent` /
///     `moveCursor` / `emptyState`）と表示用整形（`formatBody`）
///   - facade `withDialog`（Runner / WaitOnly / SceneView を 1 行で適用）
///
/// 描画やノード木の知識は持たないので、別の Scene 実装に差し替えても再利用できる。
/// 実装の handler 群は `Dialogue.Runner` / `Dialogue.Commands` /
/// `Dialogue.SceneView` / `Dialogue.StubView` の各サブモジュールにある。
mod Dialogue {

    // ════════════════════════════════════════════════════════════════════════
    // データ型
    // ════════════════════════════════════════════════════════════════════════

    /// 表示用に整形された 1 行。`text` は置換マーカー解決済み。
    pub type alias PresentedLine = {
        lineId  = String,
        text    = String,
        speaker = Option[String]
    }

    /// 表示用に整形された 1 つの選択肢。
    /// `index` は VM の `selectOption` に渡す番号と一致する。
    pub type alias PresentedOption = {
        index     = Int32,
        text      = String,
        available = Bool
    }

    /// `DialogueView` の各操作を 1 件のイベントとして表したもの。
    /// `SceneView` handler が `MutDeque` に積み、`Pump.drain` 経由で
    /// 1 フレーム分まとめて取り出される。`StubView` も同じ enum をテストログとして使う。
    pub enum ViewEvent with Eq, ToString {
        /// `presentLine` 受信。表示すべき本文。
        case Line(String)
        /// `presentOptions` 受信。表示すべき選択肢のテキスト列。
        case Options(List[String])
        /// `dismissLine` 受信。表示中の行を消す。
        case Dismiss
        /// `runCommand` 受信。実コマンド文字列。
        case Command(String)
        /// `dialogueComplete` 受信。対話完了。
        case Complete
    }

    /// 対話 UI の論理状態。Scene 表現（CanvasLayer / RichTextLabel など）から
    /// 独立した純粋データなので、別の描画実装に差し替えても再利用できる。
    pub type alias UIState = {
        text     = String,        // line モードの本文。options モードでは空。
        options  = List[String],  // 選択肢中なら non-empty。
        cursor   = Int32,         // options 内の選択中 index（0 始まり）。
        visible  = Bool           // 完了後 / 未開始は false。
    }

    // ════════════════════════════════════════════════════════════════════════
    // UIState の純粋遷移と整形
    // ════════════════════════════════════════════════════════════════════════

    /// 初期状態（未開始 = 非表示）。
    pub def emptyState(): UIState = {
        text = "",
        options = Nil,
        cursor = 0,
        visible = false
    }

    /// 1 件の `ViewEvent` を状態に反映する純粋関数。
    /// `Line` / `Options` / `Complete` のみ状態を変える。`Dismiss` / `Command` は no-op。
    pub def applyEvent(event: ViewEvent, state: UIState): UIState =
        match event {
            case ViewEvent.Line(text)       =>
                { text = text, options = Nil, cursor = 0, visible = true }
            case ViewEvent.Options(options) =>
                { text = "", options = options, cursor = 0, visible = true }
            case ViewEvent.Dismiss          => state
            case ViewEvent.Command(_)       => state
            case ViewEvent.Complete         => emptyState()
        }

    /// `delta` だけカーソルを動かした状態を返す。
    /// 範囲外は wrap-around（先頭から末尾へ、末尾から先頭へ）。
    /// options が空のときは状態を変えない。
    pub def moveCursor(delta: Int32, state: UIState): UIState =
        let optionCount = List.length(state#options);
        if (optionCount <= 0) state
        else {
            let raw = state#cursor + delta;
            let normalized =
                if (raw < 0) optionCount - 1
                else if (raw >= optionCount) 0
                else raw;
            { cursor = normalized | state }
        }

    /// 本文として表示する文字列を組み立てる。
    /// - options 空 → 本文 text をそのまま返す
    /// - options 非空 → カーソル行に `> `、それ以外に `  ` を付けて改行連結
    pub def formatBody(state: UIState): String =
        if (List.isEmpty(state#options)) state#text
        else
            List.mapWithIndex((index, option) ->
                if (index == state#cursor) "> ${option}"
                else "  ${option}",
                state#options)
                |> String.intercalate("\n")

    // ════════════════════════════════════════════════════════════════════════
    // effects
    // ════════════════════════════════════════════════════════════════════════

    /// ゲームロジック・入力レイヤ → 対話駆動の API。
    pub eff Session {
        /// 指定ノードから対話を開始する。
        def start(nodeName: String): Unit

        /// 対話を強制中断する。VM 状態をクリアし、view にも完了通知を送る。
        def stop(): Unit

        /// 現在対話実行中なら true。
        def isActive(): Bool

        /// 現在の行表示を完了し、次の命令に進む。
        def submitAdvance(): Unit

        /// 選択肢を確定する。`optionIndex` は presentOptions で渡された index と同じ。
        def submitSelect(optionIndex: Int32): Unit

        /// コマンド実行完了の通知。
        def submitCommandDone(): Unit
    }

    /// プレゼンターが満たす契約。エンジン非依存。
    /// 実エンジンに乗せるときは UI を操作する handler を `with DialogueView ...` で注入する。
    pub eff DialogueView {
        /// 1 行表示する。表示完了後、ユーザの advance を待つ。
        def presentLine(line: PresentedLine): Unit

        /// 選択肢を提示する。確定はユーザの selectOption を待つ。
        def presentOptions(options: List[PresentedOption]): Unit

        /// 表示中の行を消す（次の line / options に行く前のクリア）。
        def dismissLine(): Unit

        /// Yarn コマンドを実行依頼する。
        /// 完了は呼び出し元から `Session.submitCommandDone` で返ってくる。
        def runCommand(commandText: String): Unit

        /// 対話が完了したことを通知する。
        def dialogueComplete(): Unit
    }

    /// Yarn コマンド `runCommand` の文字列を実処理に振り分ける層。
    /// `dispatch` は「同期で完了したら true、非同期で進行中なら false」を返す。
    /// true を返した場合はランナーが続けて `Yarn.VM.commandComplete` を呼ぶ。
    /// false を返した場合はエンジン側が完了タイミングで `Session.submitCommandDone`
    /// を呼ぶことで対話を再開させる。
    pub eff CommandRegistry {
        /// 指定したコマンド名のハンドラを登録する。
        /// 戻り値は同期完了か。`withWaitOnly` 実装は登録を無視する。
        def register(name: String, action: List[String] -> Bool): Unit

        /// "wait 0.5" のようなコマンド行を実行する。同期完了なら true。
        def dispatch(commandLine: String): Bool
    }

    // ════════════════════════════════════════════════════════════════════════
    // facade — 対話 handler 一式を 1 行で適用する
    // ════════════════════════════════════════════════════════════════════════

    /// `Runner` / `WaitOnly` / `SceneView`（DialogueView + Pump）を 1 つにまとめた
    /// facade。region と event queue を内部に閉じ込めるため、呼び出し側は
    /// scene 構築・入力・gameLoop だけに集中できる。
    ///
    /// `body` 内で `Dialogue.Session.start` などを呼ぶと、view 側のイベントは
    /// `Dialogue.SceneView.Pump.drain` 経由で取り出せる（Scene 側の `process`
    /// で消化する想定）。
    pub def withDialog(yarnProject: Yarn.Types.YarnProject,
                        body: Unit -> a \ ef):
                         a \ (ef - Session - DialogueView - CommandRegistry
                                 - Dialogue.SceneView.Pump) =
        region rc {
            run body() with Dialogue.Runner.withRunner(rc, yarnProject)
                       with Dialogue.Commands.withWaitOnly
                       with Dialogue.SceneView.withSceneView(rc)
        }
}

mod Dialogue.Commands {

    /// `wait` を含むあらゆるコマンドを「即時完了」として扱うスタブ。
    /// 常に `true`（同期完了）を返すので、ランナーがそのまま次の命令へ進む。
    /// 実エンジン統合時は Tween.Scheduler 経由の真の待機に差し替える。
    pub def withWaitOnly(body: Unit -> a \ ef):
                          a \ (ef - Dialogue.CommandRegistry) =
        run body() with handler Dialogue.CommandRegistry {
            def register(_name, _action, resume) = resume()
            def dispatch(_commandLine, resume)   = resume(true)
        }
}
