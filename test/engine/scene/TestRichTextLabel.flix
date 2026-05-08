// Tests for RichTextLabel BBCode parser
//
// パーサが [color=...] タグの後ろのテキストを正しく保持することを確認する。
// 過去にタグ後の文字が丸ごと捨てられる回帰があったため、それを再発防止するテスト。

mod TestRichTextLabel {

    /// テスト用の最小 FontAtlas（パーサだけ検証するなら glyphs は不要）
    def dummyAtlas(): FontAtlas = {
        textureName = "ui",
        textureSize = 256.0,
        fontSize = 16.0,
        ascent = 14.0,
        descent = 4.0,
        lineGap = 0.0,
        glyphs = Map.empty()
    }

    /// テスト用 Color（白）
    def white(): Color = {r = 1.0f32, g = 1.0f32, b = 1.0f32}

    // ========================================================================
    // parseBBCode
    // ========================================================================

    /// タグなしのプレーンテキストはそのまま 1 文字 1 セグメントになる
    @Test
    def testParsePlainText(): Unit \ Assert =
        let segs = RichTextLabel.parseBBCode("Hi", white());
        Assert.assertEq(expected = 2, List.length(segs))

    /// [color=red]X[/color] でタグ内 1 文字 + タグ前後 0 文字 = 1 セグメント
    @Test
    def testParseColoredOnly(): Unit \ Assert =
        let segs = RichTextLabel.parseBBCode("[color=red]X[/color]", white());
        Assert.assertEq(expected = 1, List.length(segs))

    /// 回帰テスト: タグ後ろのテキストが捨てられないこと
    /// "[color=#ffffff]ABC[/color]DEF" は 6 文字（A B C D E F）になる
    @Test
    def testParseColorTagDoesNotDropTrailing(): Unit \ Assert =
        let segs = RichTextLabel.parseBBCode("[color=#ffffff]ABC[/color]DEF", white());
        Assert.assertEq(expected = 6, List.length(segs))

    /// 改行文字はそのままセグメントに残る（splitSegmentsIntoLines が改行で分割するため）
    @Test
    def testParsePreservesNewline(): Unit \ Assert =
        let segs = RichTextLabel.parseBBCode("A\nB", white());
        Assert.assertEq(expected = 3, List.length(segs))

    // ========================================================================
    // splitSegmentsIntoLines
    // ========================================================================

    /// 改行を含むテキストは複数行に分割される
    @Test
    def testSplitTwoLines(): Unit \ Assert =
        let segs = RichTextLabel.parseBBCode("A\nB", white());
        let lines = RichTextLabel.splitSegmentsIntoLines(segs);
        Assert.assertEq(expected = 2, List.length(lines))

    /// 空文字でも 1 行は返る
    @Test
    def testSplitEmptyIsOneLine(): Unit \ Assert =
        let segs = RichTextLabel.parseBBCode("", white());
        let lines = RichTextLabel.splitSegmentsIntoLines(segs);
        Assert.assertEq(expected = 1, List.length(lines))

    // ========================================================================
    // parseStyled — [b] / [color] の bold + color 状態を返す
    // ========================================================================

    /// `[b]` ネスト内の文字には bold=true が立つ。タグ外は false。
    /// "[b]A[/b]B" → [(A, bold), (B, regular)]
    @Test
    def testParseStyledBoldFlag(): Unit \ Assert =
        let segs = RichTextLabel.parseStyled("[b]A[/b]B", white());
        let flags = List.map(seg -> seg#bold, segs);
        Assert.assertEq(expected = true :: false :: Nil, flags)

    /// `[color=red][b]X[/b][/color]` で color と bold が同時に効く。
    /// X は color=red & bold=true。Color レコードは Eq 派生していないので
    /// rgb を Float32 タプルに分解して比較する。
    @Test
    def testParseStyledColorAndBoldCombined(): Unit \ Assert =
        let segs = RichTextLabel.parseStyled("[color=red][b]X[/b][/color]", white());
        let actual = match segs {
            case seg :: Nil =>
                (seg#char, seg#color#r, seg#color#g, seg#color#b, seg#bold)
            case _          => bug!("expected exactly 1 segment")
        };
        Assert.assertEq(
            expected = ('X', 1.0f32, 0.0f32, 0.0f32, true),
            actual)

    /// 入れ子 `[b][b]X[/b]Y[/b]` の Y は外側の `[b]` がまだ生きているので bold=true。
    /// boldDepth は深さでカウントされ、片方の `[/b]` で 0 にはならない。
    @Test
    def testParseStyledNestedBoldKeepsDepth(): Unit \ Assert =
        let segs = RichTextLabel.parseStyled("[b][b]X[/b]Y[/b]Z", white());
        let flags = List.map(seg -> seg#bold, segs);
        Assert.assertEq(expected = true :: true :: false :: Nil, flags)

    // ========================================================================
    // setBoldFontAtlas — bold アトラス注入
    // ========================================================================

    /// 新規追加した名前付き色（gold / lime / pink）が正しい RGB 値で解釈される。
    /// 各タグ内 1 文字を `parseStyled` で取り出し、`color#r,g,b` を確認する。
    @Test
    def testParseNamedColorExtras(): Unit \ Assert =
        let firstSegColor = (text: String) ->
            match RichTextLabel.parseStyled(text, white()) {
                case seg :: _ => (seg#color#r, seg#color#g, seg#color#b)
                case Nil      => bug!("expected at least 1 segment for: ${text}")
            };
        let actual = (
            firstSegColor("[color=gold]A[/color]"),
            firstSegColor("[color=lime]A[/color]"),
            firstSegColor("[color=pink]A[/color]")
        );
        let expected = (
            (1.0f32,  0.84f32, 0.0f32),   // gold
            (0.0f32,  1.0f32,  0.0f32),   // lime
            (1.0f32,  0.75f32, 0.8f32)    // pink
        );
        Assert.assertEq(expected = expected, actual)

    /// `setBoldFontAtlas` を当てたあと、`clearBoldFontAtlas` で解除できる。
    /// `make` 直後は未設定（None）であることも 1 度に確認する。
    @Test
    def testBoldFontAtlasLifecycle(): Unit \ Assert =
        let label = RichTextLabel.make("x", dummyAtlas(), 16.0, {x = 100.0, y = 20.0});
        let setLabel = RichTextLabel.setBoldFontAtlas(dummyAtlas(), label);
        let clearedLabel = RichTextLabel.clearBoldFontAtlas(setLabel);
        let extract = lbl -> {
            let RichTextLabel.RichTextLabel(r) = lbl;
            r#boldFontAtlas
        };
        let states = (extract(label), extract(setLabel), extract(clearedLabel));
        let isSet = match states {
            case (None, Some(_), None) => true
            case _                     => false
        };
        Assert.assertTrue(isSet)

    // ========================================================================
    // setText + scrollFollowing
    // ========================================================================

    /// scrollFollowing=true にした RichTextLabel に setText すると、
    /// 内容が表示領域より大きい場合に scrollY が末尾まで進む
    @Test
    def testScrollFollowingAdvancesScrollY(): Unit \ Assert =
        let label = RichTextLabel.make("", dummyAtlas(), 16.0, {x = 100.0, y = 10.0})
                    |> RichTextLabel.setScrollFollowing(true)
                    |> RichTextLabel.setText("L1\nL2\nL3\nL4\nL5\nL6");
        let scrollY = RichTextLabel.getScrollY(label);
        // 6 行 × lineHeight (= 18) = 108 > 10 なので末尾追従が発火する
        Assert.assertTrue(scrollY > 0.0)

    /// scrollFollowing=false なら setText しても scrollY は 0 のまま
    @Test
    def testScrollFollowingFalseKeepsScrollY(): Unit \ Assert =
        let label = RichTextLabel.make("", dummyAtlas(), 16.0, {x = 100.0, y = 10.0})
                    |> RichTextLabel.setText("L1\nL2\nL3\nL4\nL5\nL6");
        Assert.assertEq(expected = 0.0, RichTextLabel.getScrollY(label))
}
