/// `Yarn.Markup.toBBCode` のテスト。
///
/// 当面は `Markup.BBCode.parse |> render` の round-trip なので、
/// 平文も BBCode タグ付き文字列も意味的には保たれることを確認する。
mod TestYarnMarkup {

    /// 空文字は空文字のまま
    @Test
    def testToBBCodeEmpty(): Unit \ Assert =
        Assert.assertEq(expected = "", Yarn.Markup.toBBCode(""))

    /// 平文（タグ無し）は変化しない
    @Test
    def testToBBCodePlainText(): Unit \ Assert =
        Assert.assertEq(expected = "こんにちは", Yarn.Markup.toBBCode("こんにちは"))

    /// 改行を含む複数行も保たれる
    @Test
    def testToBBCodePreservesNewlines(): Unit \ Assert =
        Assert.assertEq(expected = "L1\nL2\nL3", Yarn.Markup.toBBCode("L1\nL2\nL3"))

    /// 単純な color タグは round-trip で保たれる
    @Test
    def testToBBCodeColorTagRoundTrip(): Unit \ Assert =
        Assert.assertEq(expected = "[color=red]X[/color]", Yarn.Markup.toBBCode("[color=red]X[/color]"))

    /// 周辺テキスト付きの color タグも保たれる
    @Test
    def testToBBCodeColorTagWithSurroundingText(): Unit \ Assert =
        Assert.assertEq(expected = "前[color=red]中[/color]後", Yarn.Markup.toBBCode("前[color=red]中[/color]後"))

    /// 不正タグ（空タグ）はリテラルとしてそのまま戻る
    @Test
    def testToBBCodePreservesLiteralBracket(): Unit \ Assert =
        Assert.assertEq(expected = "pre[]post", Yarn.Markup.toBBCode("pre[]post"))
}
