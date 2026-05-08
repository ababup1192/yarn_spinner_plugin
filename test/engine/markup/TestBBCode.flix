/// `Markup.BBCode.parse` のテスト。
///
/// テキスト・開始タグ・終了タグ・属性付きタグ・ネスト・エッジケース
/// （未閉じ・空タグ・不正属性）が期待通りトークン化されることを確認する。
mod TestBBCode {
    use Markup.BBCode.Token
    use Markup.BBCode.Token.{Text, OpenTag, CloseTag}

    // ========================================================================
    // 平文 / 単純タグ
    // ========================================================================

    /// タグが無い純粋なテキストは Text 1 個になる
    @Test
    def testParsePlainText(): Unit \ Assert =
        let tokens = Markup.BBCode.parse("hello");
        Assert.assertEq(expected = Text("hello") :: Nil, tokens)

    /// `[b]X[/b]` は OpenTag / Text / CloseTag の 3 トークン
    @Test
    def testParseSimpleOpenAndClose(): Unit \ Assert =
        let tokens = Markup.BBCode.parse("[b]X[/b]");
        let expected: List[Token] =
            OpenTag("b", Map.empty()) ::
            Text("X") ::
            CloseTag("b") ::
            Nil;
        Assert.assertEq(expected = expected, tokens)

    // ========================================================================
    // 属性付き
    // ========================================================================

    /// `[color=red]` は属性 Map にタグ名と同じキーで値が入る
    @Test
    def testParseValueShorthand(): Unit \ Assert =
        let tokens = Markup.BBCode.parse("[color=red]");
        let expected: List[Token] =
            OpenTag("color", Map#{"color" => "red"}) :: Nil;
        Assert.assertEq(expected = expected, tokens)

    /// `[wave amp=2 speed=1]` は複数属性を Map にまとめる
    @Test
    def testParseMultipleAttrs(): Unit \ Assert =
        let tokens = Markup.BBCode.parse("[wave amp=2 speed=1]");
        let expected: List[Token] =
            OpenTag("wave", Map#{"amp" => "2", "speed" => "1"}) :: Nil;
        Assert.assertEq(expected = expected, tokens)

    /// `[url=http://x?a=b]` のように値に `=` を含めても 1 つの値として保持される
    @Test
    def testParseValueContainingEquals(): Unit \ Assert =
        let tokens = Markup.BBCode.parse("[url=http://x?a=b]");
        let expected: List[Token] =
            OpenTag("url", Map#{"url" => "http://x?a=b"}) :: Nil;
        Assert.assertEq(expected = expected, tokens)

    // ========================================================================
    // ネスト / 周辺テキスト
    // ========================================================================

    /// `A[c=red]B[/c]C` でネストせず前後にも Text が並ぶ
    @Test
    def testParseSurroundingText(): Unit \ Assert =
        let tokens = Markup.BBCode.parse("A[c=red]B[/c]C");
        let expected: List[Token] =
            Text("A") ::
            OpenTag("c", Map#{"c" => "red"}) ::
            Text("B") ::
            CloseTag("c") ::
            Text("C") ::
            Nil;
        Assert.assertEq(expected = expected, tokens)

    /// 多重ネスト `[a][b]X[/b][/a]` は 5 トークンになり順序が保たれる
    @Test
    def testParseNested(): Unit \ Assert =
        let tokens = Markup.BBCode.parse("[a][b]X[/b][/a]");
        let expected: List[Token] =
            OpenTag("a", Map.empty()) ::
            OpenTag("b", Map.empty()) ::
            Text("X") ::
            CloseTag("b") ::
            CloseTag("a") ::
            Nil;
        Assert.assertEq(expected = expected, tokens)

    // ========================================================================
    // エッジケース（リテラル化）
    // ========================================================================

    /// 閉じ括弧がない `[abc` は `[` ごと Text として残る
    @Test
    def testParseUnclosedBracketIsLiteral(): Unit \ Assert =
        let tokens = Markup.BBCode.parse("[abc");
        Assert.assertEq(expected = Text("[abc") :: Nil, tokens)

    /// 空タグ `[]` はリテラルとして `Text("[]")` になる
    @Test
    def testParseEmptyTagIsLiteral(): Unit \ Assert =
        let tokens = Markup.BBCode.parse("[]");
        Assert.assertEq(expected = Text("[]") :: Nil, tokens)

    /// `=` なし属性を含むタグ全体が不正としてリテラル化される
    @Test
    def testParseBareAttrIsLiteral(): Unit \ Assert =
        let tokens = Markup.BBCode.parse("[name attr]");
        Assert.assertEq(expected = Text("[name attr]") :: Nil, tokens)

    /// 終了タグに余分な空白文字付きの内容（`[/color extra]`）はリテラル化
    @Test
    def testParseInvalidCloseTagIsLiteral(): Unit \ Assert =
        let tokens = Markup.BBCode.parse("[/color extra]");
        Assert.assertEq(expected = Text("[/color extra]") :: Nil, tokens)

    /// 周辺テキストとリテラル化タグが正しく結合される
    @Test
    def testParseLiteralMergesWithSurroundingText(): Unit \ Assert =
        let tokens = Markup.BBCode.parse("pre[]post");
        Assert.assertEq(expected = Text("pre[]post") :: Nil, tokens)

    // ========================================================================
    // 未対応タグの保持
    // ========================================================================

    /// 利用側にとって未対応な `[wave]` も OpenTag としてそのまま運ばれる
    /// （リテラル化はパース不能なときだけで、未知タグは構造を保つ）
    @Test
    def testParsePreservesUnknownTagStructure(): Unit \ Assert =
        let tokens = Markup.BBCode.parse("[wave]hi[/wave]");
        let expected: List[Token] =
            OpenTag("wave", Map.empty()) ::
            Text("hi") ::
            CloseTag("wave") ::
            Nil;
        Assert.assertEq(expected = expected, tokens)

    // ========================================================================
    // 可視文字数 / 可視 slice — typewriter 用
    // ========================================================================

    /// `visibleLength` は Text 部分のみ集計し、タグ本体（`[color=red]` など）は
    /// 0 として扱う。タグなし / タグあり / 入れ子 をまとめて確認する。
    @Test
    def testVisibleLengthIgnoresTags(): Unit \ Assert =
        let plain  = Markup.BBCode.visibleLength("hello");
        let tagged = Markup.BBCode.visibleLength("[color=red]hi[/color]");
        let nested = Markup.BBCode.visibleLength("[b][color=red]ab[/color]c[/b]");
        Assert.assertEq(expected = (5, 2, 3), (plain, tagged, nested))

    /// `sliceVisible` は可視 N 文字までで切り、開いていた色タグを末尾で閉じる。
    /// 入力 "[color=red]ABCD[/color]" の N=2 は `[color=red]AB[/color]` を返す。
    @Test
    def testSliceVisibleClosesOpenTagsAtCut(): Unit \ Assert =
        let actual = Markup.BBCode.sliceVisible("[color=red]ABCD[/color]", 2);
        Assert.assertEq(expected = "[color=red]AB[/color]", actual)

    /// N が visibleLength を超えた場合はテキスト全体がそのまま返る。
    /// N=0 / 負値は空文字 / タグだけの状態（開いていれば閉じる）。
    @Test
    def testSliceVisibleEdgeCases(): Unit \ Assert =
        let beyond  = Markup.BBCode.sliceVisible("[color=red]ABC[/color]", 99);
        let zero    = Markup.BBCode.sliceVisible("[color=red]ABC[/color]", 0);
        let negative = Markup.BBCode.sliceVisible("[color=red]ABC[/color]", -1);
        let plain   = Markup.BBCode.sliceVisible("hello", 3);
        Assert.assertEq(
            expected = ("[color=red]ABC[/color]", "", "", "hel"),
            (beyond, zero, negative, plain))

    /// 入れ子の途中で切るときは内側 → 外側の順で閉じる。
    /// 入力 "[color=red][b]abcd[/b][/color]" の N=2 は
    /// `[color=red][b]ab[/b][/color]`（b → color の順で閉じる）を期待。
    @Test
    def testSliceVisibleNestedTagsClosedInLifoOrder(): Unit \ Assert =
        let actual = Markup.BBCode.sliceVisible("[color=red][b]abcd[/b][/color]", 2);
        Assert.assertEq(expected = "[color=red][b]ab[/b][/color]", actual)
}
