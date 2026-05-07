/// Dialogue 層の effect とデータ型を集約するモジュール。
///
/// 3 つの effect を提供する：
///
///   - `Dialog`           ゲームロジック側の API（start / submitAdvance / ...）
///   - `DialogueView`     プレゼンター側の契約（presentLine / presentOptions / ...）
///   - `CommandRegistry`  Yarn コマンド `runCommand` 文字列を実処理に振り分ける層
///
/// 加えて、view 用の整形済み型 `PresentedLine` / `PresentedOption` を置く。
/// 役割が明確なので 1 ファイルに集約しても見通しは保てる。
///
/// 実装は `Dialogue.Runner.withRunner`、`Dialogue.Commands.withWaitOnly`、
/// `Dialogue.StubView.withRecordingView`（テスト用）に分かれる。
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

    // ════════════════════════════════════════════════════════════════════════
    // effects
    // ════════════════════════════════════════════════════════════════════════

    /// ゲームロジック・入力レイヤ → 対話駆動の API。
    pub eff Dialog {
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
        /// 完了は呼び出し元から `Dialog.submitCommandDone` で返ってくる。
        def runCommand(commandText: String): Unit

        /// 対話が完了したことを通知する。
        def dialogueComplete(): Unit
    }

    /// Yarn コマンド `runCommand` の文字列を実処理に振り分ける層。
    /// `dispatch` は「同期で完了したら true、非同期で進行中なら false」を返す。
    /// true を返した場合はランナーが続けて `Yarn.VM.commandComplete` を呼ぶ。
    /// false を返した場合はエンジン側が完了タイミングで `Dialog.submitCommandDone`
    /// を呼ぶことで対話を再開させる。
    pub eff CommandRegistry {
        /// 指定したコマンド名のハンドラを登録する。
        /// 戻り値は同期完了か。`withWaitOnly` 実装は登録を無視する。
        def register(name: String, action: List[String] -> Bool): Unit

        /// "wait 0.5" のようなコマンド行を実行する。同期完了なら true。
        def dispatch(commandLine: String): Bool
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
