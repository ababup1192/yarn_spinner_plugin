/// Dialogue 層の effect・型・純粋遷移を集約するモジュール。
///
/// 提供するもの:
///
///   - 3 つの effect: `Session` / `DialogueView` / `CommandRegistry`
///   - view 用の整形済み型: `PresentedLine` / `PresentedOption`
///   - 1 フレーム単位で受け渡す view イベント: `ViewEvent`
///   - 対話 UI の論理状態: `UIState` と、その純粋遷移（`applyEvent` /
///     `moveCursor` / `emptyState`）と表示用整形（`formatBody`）
///   - ジャンルごとのリズム・寸法をまとめた `DialogueProfile` と既製 profile
///     （`jrpgProfile` / `visualNovelProfile`）
///   - facade `withDialog`（Runner / WaitOnly / SceneView を 1 行で適用）
///
/// 描画やノード木の知識は持たないので、別の Scene 実装に差し替えても再利用できる。
/// JRPG / VN / その他の表現スタイルの違いは `DialogueProfile` の値で吸収する。
mod Dialogue {

    // ════════════════════════════════════════════════════════════════════════
    // データ型
    // ════════════════════════════════════════════════════════════════════════

    /// 表示用に整形された 1 行。`text` は置換マーカー解決済み。
    /// `speaker` は表記から取り出した話者名。Runner / Scene が `extractSpeaker` を
    /// 使って埋める想定だが、別の表記法を使うシナリオでは独自に詰めて良い。
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
        /// `presentLine` 受信。本文と、表記から取り出した話者名（無ければ `None`）。
        case Line(String, Option[String])
        /// `presentOptions` 受信。表示すべき選択肢のテキスト列。
        case Options(List[String])
        /// `dismissLine` 受信。表示中の行を消す。
        case Dismiss
        /// `runCommand` 受信。実コマンド文字列。
        case Command(String)
        /// `dialogueComplete` 受信。対話完了。
        case Complete
    }

    /// 古い行のスクロール / フェード演出。`progress` は 0.0 → 1.0 で進む。
    /// `oldLines` は演出開始時のパネルに表示されていた行列を保持する。
    pub type alias Transition = {
        oldLines = List[String],
        progress = Float64
    }

    /// ジャンルごとの「対話リズム・寸法」をまとめた値。
    /// `UIState` が 1 つ保持し、純粋遷移はそこから読み出すことでコードの分岐を減らす。
    /// Scene 構築時に `jrpgProfile()` / `visualNovelProfile()` から選ぶか、
    /// 個別フィールドを上書きしてカスタムプロファイルを作る。
    ///
    /// フィールド:
    ///   - `maxLinesPerPanel`: 1 パネルに溜める最大行数。1 で行ごとパネル切替（VN 風）
    ///   - `breakOnSpeakerLine`: 名前 prefix 付き Line を「新パネル + 確定キー待ち」扱いにするか。
    ///       false なら名前 prefix は単なる装飾（log スタイル等）
    ///   - `autoAdvanceContinuation`: 継続行で typewriter 完了時に自動で次へ進めるか。
    ///       false なら毎行確定キーが要る（VN 風）
    ///   - `transitionDuration`: パネル切り替え演出の継続時間
    ///   - `revealCharsPerSecond`: typewriter の送出速度（文字 / 秒）
    ///   - `blinkPeriod`: 続行待ちインジケータの点滅 1 サイクル長。半周期で ON/OFF 切替
    ///   - `advanceIndicatorGlyph`: 続行待ちインジケータの表示記号。描画側で表示可能なフォントを用意する
    pub type alias DialogueProfile = {
        maxLinesPerPanel          = Int32,
        breakOnSpeakerLine        = Bool,
        autoAdvanceContinuation   = Bool,
        transitionDuration        = Duration.Duration,
        revealCharsPerSecond      = Float64,
        blinkPeriod               = Duration.Duration,
        advanceIndicatorGlyph     = String
    }

    /// JRPG 風（3 行パネル / 名前 prefix で待機 / 継続行は自動送り / "▼" 点滅）。
    pub def jrpgProfile(): DialogueProfile = {
        maxLinesPerPanel          = 3,
        breakOnSpeakerLine        = true,
        autoAdvanceContinuation   = true,
        transitionDuration        = Duration.seconds(0.6),
        revealCharsPerSecond      = 40.0,
        blinkPeriod               = Duration.seconds(0.5),
        advanceIndicatorGlyph     = "▼"
    }

    /// ビジュアルノベル風（1 行 1 パネル / 毎行確定キー待ち / 軽い演出）。
    pub def visualNovelProfile(): DialogueProfile = {
        maxLinesPerPanel          = 1,
        breakOnSpeakerLine        = false,
        autoAdvanceContinuation   = false,
        transitionDuration        = Duration.seconds(0.2),
        revealCharsPerSecond      = 50.0,
        blinkPeriod               = Duration.seconds(0.5),
        advanceIndicatorGlyph     = "▼"
    }

    /// 対話 UI の論理状態。Scene 表現（CanvasLayer / RichTextLabel など）から
    /// 独立した純粋データなので、別の描画実装に差し替えても再利用できる。
    ///
    /// 設計:
    ///   - `lines` は同じ話者の発話を `profile#maxLinesPerPanel` まで蓄積する（古→新）
    ///   - `profile#breakOnSpeakerLine` が true の場合、名前 prefix 付き Line は新パネル化扱い：
    ///     - 旧 lines を `transition` に退避してスクロールアウトする
    ///     - 適用したいイベント本体は `pendingEvent` に保留しておき、transition が
    ///       完了してから `applyEventInner` で実際に反映する
    ///       （= 演出が終わるまで次の文章は出さない）
    ///   - 上限超え / Options / Complete も同じく新パネル化扱い
    ///   - 名前なし継続 Line のあとは `lastLineHadName = false`。typewriter 完了時に
    ///     `profile#autoAdvanceContinuation` が true なら `shouldAutoAdvance` が true になり、
    ///     Scene 側 process が自動 submitAdvance を呼ぶ
    ///   - typewriter は `lines` 全体（連続文字列扱い）にかかる
    pub type alias UIState = {
        speaker         = Option[String],     // 現在のパネルの話者（":" の左側から抽出）
        lines           = List[String],       // 蓄積中の発話（古→新）
        options         = List[String],       // 選択肢中なら non-empty
        cursor          = Int32,              // options 内の選択中 index（0 始まり）
        visible         = Bool,               // 完了後 / 未開始は false
        revealProgress  = Float64,            // パネル全体の typewriter 進捗（文字数累積）
        elapsed         = Duration.Duration,  // 表示中の経過時間（点滅用）
        lastLineHadName = Bool,               // 最新 line に名前 prefix が付いていたか
        transition      = Option[Transition], // 直前パネルのスクロール演出
        pendingEvent    = Option[ViewEvent],  // transition 完了後に適用するイベント
        profile         = DialogueProfile     // ジャンルごとのリズム・寸法
    }

    // ════════════════════════════════════════════════════════════════════════
    // UIState の純粋遷移と整形
    // ════════════════════════════════════════════════════════════════════════

    /// 初期状態（未開始 = 非表示）。`profile` で表現スタイルを選ぶ。
    pub def emptyState(profile: DialogueProfile): UIState = {
        speaker = None,
        lines = Nil,
        options = Nil,
        cursor = 0,
        visible = false,
        revealProgress = 0.0,
        elapsed = Duration.zero(),
        lastLineHadName = false,
        transition = None,
        pendingEvent = None,
        profile = profile
    }

    /// `text` の "<speaker>:" 部分を取り出す。コロンが無ければ `None`。
    /// 区切りは Yarn の慣例に合わせ半角 `:` のみ。全角コロン `：` を使う場合は
    /// 呼び出し側で正規化するか、独自の抽出関数で `PresentedLine#speaker` を埋める。
    pub def extractSpeaker(text: String): Option[String] =
        let indexed = List.zipWithIndex(String.toList(text));
        match List.find(match (_, c) -> c == ':', indexed) {
            case Some((idx, _)) =>
                let speaker = String.slice(start = 0, end = idx, text);
                Some(String.trim(speaker))
            case None => None
        }

    /// 1 件の `ViewEvent` を状態に反映する純粋関数。
    /// `eventStartsNewPanel` が真なら旧 lines を transition に退避し、イベント本体は
    /// `pendingEvent` に保留する（transition 完了後に `applyEventInner` で適用）。
    /// 偽なら直ちに `applyEventInner` で反映する。
    pub def applyEvent(event: ViewEvent, state: UIState): UIState =
        if (eventStartsNewPanel(event, state))
            beginPanelTransition(event, state)
        else
            applyEventInner(event, state)

    /// イベントを受けたら **新パネル化** すべきか。lines が空のときは false（最初の行は
    /// 即時表示してよい。transition する旧 lines も無いので保留する意味も無い）。
    def eventStartsNewPanel(event: ViewEvent, state: UIState): Bool =
        if (List.isEmpty(state#lines)) false
        else match event {
            case ViewEvent.Line(_, speaker) =>
                (state#profile#breakOnSpeakerLine and Option.nonEmpty(speaker))
                or List.length(state#lines) >= state#profile#maxLinesPerPanel
            case ViewEvent.Options(_) => true
            case ViewEvent.Complete   => true
            case ViewEvent.Dismiss    => false
            case ViewEvent.Command(_) => false
        }

    /// 旧 lines を transition に退避し、イベント適用を transition 完了まで保留する。
    def beginPanelTransition(event: ViewEvent, state: UIState): UIState =
        let nextTransition =
            if (Option.nonEmpty(state#transition)) state#transition
            else Some({ oldLines = state#lines, progress = 0.0 });
        { speaker = state#speaker,
           lines = Nil,
           options = Nil,
           cursor = 0,
           visible = true,
           revealProgress = 0.0,
           elapsed = state#elapsed,
           lastLineHadName = state#lastLineHadName,
           transition = nextTransition,
           pendingEvent = Some(event),
           profile = state#profile }

    /// transition を伴わない実適用ロジック。
    /// `applyEvent` 直接呼び出し（lines 空 / 継続 line / Dismiss / Command）と、
    /// `tickTransition` 完了後の `pendingEvent` 反映の両方から呼ばれる。
    def applyEventInner(event: ViewEvent, state: UIState): UIState =
        match event {
            case ViewEvent.Line(text, speaker) => acceptLineInner(text, speaker, state)
            case ViewEvent.Options(options)    => startOptionsInner(options, state)
            case ViewEvent.Dismiss             => state
            case ViewEvent.Command(_)          => state
            case ViewEvent.Complete            =>
                { elapsed = state#elapsed | emptyState(state#profile) }
        }

    /// transition なしで Line を反映する。lines 空なら新規行として、非空なら append として扱う。
    /// （新パネルが必要な状況は `applyEvent` 側で `pendingEvent` に逃がしている）
    def acceptLineInner(text: String, speaker: Option[String], state: UIState): UIState =
        let hasName = Option.nonEmpty(speaker);
        if (List.isEmpty(state#lines))
            // 初回 / transition 後の最初の行
            { speaker = if (hasName) speaker else state#speaker,
               lines = text :: Nil,
               options = Nil,
               cursor = 0,
               visible = true,
               revealProgress = 0.0,
               elapsed = state#elapsed,
               lastLineHadName = hasName,
               transition = state#transition,
               pendingEvent = None,
               profile = state#profile }
        else
            // 継続 line（名前なし & 上限内）。typewriter は連続のまま。
            { speaker = state#speaker,
               lines = List.append(state#lines, text :: Nil),
               options = Nil,
               cursor = 0,
               visible = true,
               revealProgress = state#revealProgress,
               elapsed = state#elapsed,
               lastLineHadName = false,
               transition = state#transition,
               pendingEvent = None,
               profile = state#profile }

    /// transition なしで Options を反映する。
    def startOptionsInner(options: List[String], state: UIState): UIState =
        { speaker = None,
           lines = Nil,
           options = options,
           cursor = 0,
           visible = true,
           revealProgress = 0.0,
           elapsed = state#elapsed,
           lastLineHadName = false,
           transition = state#transition,
           pendingEvent = None,
           profile = state#profile }

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

    /// 1 フレーム経過分の更新。typewriter / transition / 経過時間の 3 つを進める。
    pub def tick(delta: Duration.Duration, state: UIState): UIState =
        state
            |> tickReveal(delta)
            |> tickTransition(delta)
            |> tickElapsed(delta)

    /// 表示中の経過時間を進める。点滅などのアニメーションに使う。
    def tickElapsed(delta: Duration.Duration, state: UIState): UIState =
        if (not state#visible) state
        else { elapsed = Duration.add(state#elapsed, delta) | state }

    /// パネル内の全行の合計文字数。typewriter は **panel 全体を 1 つの連続列** として
    /// 進むため、cap や完了判定はこの合計と比較する。
    def totalCharCount(state: UIState): Int32 =
        List.foldLeft((acc, line) -> acc + String.length(line), 0, state#lines)

    /// typewriter を進める内部関数。cap は **panel 内全行の合計文字数**。
    /// 行が append されると cap が伸びるので、そのまま typewriter が次行へ流れていく。
    def tickReveal(delta: Duration.Duration, state: UIState): UIState =
        if (not state#visible) state
        else if (not List.isEmpty(state#options)) state
        else if (List.isEmpty(state#lines)) state
        else {
            let cap = Int32.toFloat64(totalCharCount(state));
            let dt = Duration.toSeconds(delta);
            let advanced =
                state#revealProgress + dt * state#profile#revealCharsPerSecond;
            { revealProgress = Float64.min(cap, advanced) | state }
        }

    /// transition の `progress` を進め、1.0 を超えたら `None` に戻す。
    /// ちょうど完了したフレームで `pendingEvent` を `applyEventInner` で反映する
    /// （= 演出が終わるまで次の文章は出さないというゲート）。
    def tickTransition(delta: Duration.Duration, state: UIState): UIState =
        match state#transition {
            case None => state
            case Some(transition) =>
                let advanced =
                    transition#progress + Duration.toSeconds(delta) / Duration.toSeconds(state#profile#transitionDuration);
                if (advanced >= 1.0) {
                    let cleared = { transition = None | state };
                    match state#pendingEvent {
                        case None => cleared
                        case Some(event) =>
                            applyEventInner(event, { pendingEvent = None | cleared })
                    }
                } else {
                    let updated: Transition = { progress = advanced | transition };
                    { transition = Some(updated) | state }
                }
        }

    /// **パネル全体** が完全に表示済みなら true。
    /// options モード（typewriter 対象外）と非表示・未開始は常に true 扱い。
    pub def isLineFullyRevealed(state: UIState): Bool =
        if (not state#visible) true
        else if (not List.isEmpty(state#options)) true
        else if (List.isEmpty(state#lines)) true
        else state#revealProgress >= Int32.toFloat64(totalCharCount(state))

    /// typewriter を即座に完了させる（パネル内の残り文字を一気に表示）。
    pub def forceFullReveal(state: UIState): UIState =
        { revealProgress = Int32.toFloat64(totalCharCount(state)) | state }

    /// パネルに表示する本文を組み立てる。
    /// - options 非空 → カーソル行に `> `、それ以外に `  ` を付けて改行連結
    /// - line モード → `revealProgress` 文字数を全行に **連続して** 分配し、
    ///   各行を「self.length 以下に切り詰めた可視部分」で組み立てて改行連結。
    ///   続行 ▼ インジケータは別ノードで描画するためここには含めない。
    pub def formatBody(state: UIState): String =
        if (not List.isEmpty(state#options))
            List.mapWithIndex((index, option) ->
                if (index == state#cursor) "> ${option}"
                else "  ${option}",
                state#options)
                |> String.intercalate("\n")
        else if (List.isEmpty(state#lines)) ""
        else {
            let revealed =
                Float64.floor(state#revealProgress)
                    |> Float64.tryToInt32
                    |> Option.getWithDefault(0)
                    |> Int32.max(0);
            let step = (acc, line) -> {
                let (rendered, remaining) = acc;
                let take = Int32.min(remaining, String.length(line));
                let visible = String.take(Int32.max(0, take), line);
                (List.append(rendered, visible :: Nil), remaining - take)
            };
            let (linesOut, _) =
                List.foldLeft(step, ((Nil: List[String]), revealed), state#lines);
            String.intercalate("\n", linesOut)
        }

    /// transition が表示中なら、その内容（テキスト・進捗）を返す。
    /// 描画レイヤ側でスクロール量・modulate フェードに換算する。
    pub def transitionView(state: UIState): Option[Transition] =
        state#transition

    /// パネル全体が typewriter 完了 + 入出力待ちが何も無い状態かどうか（共通プレディケート）。
    def isPanelIdle(state: UIState): Bool =
        state#visible
            and List.isEmpty(state#options)
            and Option.isEmpty(state#transition)
            and Option.isEmpty(state#pendingEvent)
            and isLineFullyRevealed(state)
            and not List.isEmpty(state#lines)

    /// **ユーザの確定キーを待っている** 状況なら true。
    /// 「名前 prefix の Line で締められた panel」または「上限まで埋まった panel」が対象。
    /// `profile#breakOnSpeakerLine` が false なら名前 prefix は無視され、
    /// 上限ベースの判定だけになる。
    pub def shouldShowAdvanceIndicator(state: UIState): Bool =
        isPanelIdle(state)
            and ((state#profile#breakOnSpeakerLine and state#lastLineHadName)
                 or List.length(state#lines) >= state#profile#maxLinesPerPanel)

    /// **自動で次の Line に進む** べき状況なら true。
    /// `profile#autoAdvanceContinuation` が true で、名前 prefix なしの継続行のあと、
    /// まだ panel に余裕があるとき。Scene 側 process がこれを見て `Session.submitAdvance` を呼ぶ。
    pub def shouldAutoAdvance(state: UIState): Bool =
        isPanelIdle(state)
            and state#profile#autoAdvanceContinuation
            and not (state#profile#breakOnSpeakerLine and state#lastLineHadName)
            and List.length(state#lines) < state#profile#maxLinesPerPanel

    /// 点滅インジケータの ON/OFF を `elapsed` から決める。
    /// 半周期ごとに切り替わる（`profile#blinkPeriod` × 2 で 1 サイクル）。
    pub def isBlinkOn(state: UIState): Bool =
        let cycles =
            Float64.floor(Duration.toSeconds(state#elapsed) / Duration.toSeconds(state#profile#blinkPeriod))
                |> Float64.tryToInt32
                |> Option.getWithDefault(0);
        Int32.modulo(cycles, 2) == 0

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
