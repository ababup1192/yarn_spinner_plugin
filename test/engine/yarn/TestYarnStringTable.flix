/// 文字列テーブルの置換マーカー処理のテスト。
mod TestYarnStringTable {

    /// 置換が無い行はそのまま返る。
    @Test
    def testResolveNoSubstitutions(): Unit \ Assert =
        let table = Map#{"line:a" => "こんにちは"};
        let result = Yarn.StringTable.resolve("line:a", Nil, table);
        let expected: Result[String, String] = Ok("こんにちは");
        Assert.assertEq(expected = expected, result)

    /// `{0}` が 1 個の行は substitutions[0] で置き換わる。
    @Test
    def testResolveSingleSubstitution(): Unit \ Assert =
        let table = Map#{"line:b" => "HPは {0} ある"};
        let result = Yarn.StringTable.resolve("line:b", "5" :: Nil, table);
        let expected: Result[String, String] = Ok("HPは 5 ある");
        Assert.assertEq(expected = expected, result)

    /// 行が見つからない場合は Err。
    @Test
    def testResolveLineNotFound(): Unit \ Assert =
        let table: Map[String, String] = Map.empty();
        match Yarn.StringTable.resolve("line:missing", Nil, table) {
            case Err(_) => Assert.assertTrue(true)
            case _      => bug!("expected Err for missing line")
        }
}
