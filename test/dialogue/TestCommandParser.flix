/// `Dialogue.CommandParser.parse` の単体テスト。
///
/// 純粋関数なので region 不要。`<<` `>>` を剥がしたあとの text を parse できることを確認する。
mod TestCommandParser {

    /// 1 引数のシンプルなコマンド。`<<wait 0.5>>` 由来の "wait 0.5" が分解される。
    @Test
    def testParseSingleArgument(): Unit \ Assert =
        let actual = Dialogue.CommandParser.parse("wait 0.5");
        Assert.assertEq(expected = ("wait", "0.5" :: Nil), actual)

    /// 複数引数のコマンド。`<<bgm play title loop>>` 由来。
    /// 並びの保存（先頭が name、残りが args 順）を 1 度に確認する。
    @Test
    def testParseMultipleArguments(): Unit \ Assert =
        let actual = Dialogue.CommandParser.parse("bgm play title loop");
        Assert.assertEq(
            expected = ("bgm", "play" :: "title" :: "loop" :: Nil),
            actual)

    /// 引数なしのコマンド + 空文字 / 空白のみのケースをまとめて確認する。
    /// 空文字は `("", Nil)`、引数なしは `(name, Nil)`、連続空白は無視されること。
    @Test
    def testParseEdgeCases(): Unit \ Assert =
        let withoutArgs = Dialogue.CommandParser.parse("save");
        let empty       = Dialogue.CommandParser.parse("");
        let blanks      = Dialogue.CommandParser.parse("   ");
        let extraSpaces = Dialogue.CommandParser.parse("  bgm   fade   1.0  ");
        Assert.assertEq(
            expected = (
                ("save", Nil),
                ("", Nil),
                ("", Nil),
                ("bgm", "fade" :: "1.0" :: Nil)
            ),
            (withoutArgs, empty, blanks, extraSpaces))
}
