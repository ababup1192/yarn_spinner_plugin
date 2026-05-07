/// Yarn ローダのテスト。
///
/// `TestYarnFixture.outputJsonText()` で fixture をインライン取得し、
/// 実物を parse して構造の妥当性を確認する。ファイルシステム依存はない。
/// 命令ごとの単体テストは VM テストに任せ、ここは「ロード後の全体像」が
/// 期待どおりかをチェックする。
mod TestYarnLoader {
    use Yarn.Types.{Value, YarnProject, Program, YarnNode, Instruction}
    use Yarn.Types.Value.{BoolV, FloatV, StringV}
    use Yarn.Types.Instruction.{RunLine, AddOption, ShowOptions, Return, RunNode}
    use Yarn.Loader.YarnLoadError

    // ========================================================================
    // 構造: トップレベル
    // ========================================================================

    /// 3 つのノード Start / Quest / End がロードされる。
    @Test
    def testTopLevelNodeNames(): Unit \ Assert =
        let loaded = TestYarnFixture.loadProject();
        let nodeNames = Map.keysOf(loaded#program#nodes) |> Set.toList |> List.sort;
        Assert.assertEq(expected = "End" :: "Quest" :: "Start" :: Nil, nodeNames)

    /// 文字列テーブルに 9 行（はい/いいえ/各セリフ）が入っている。
    @Test
    def testStringsTableSize(): Unit \ Assert =
        let loaded = TestYarnFixture.loadProject();
        Assert.assertEq(expected = 9, Map.size(loaded#strings))

    // ========================================================================
    // 構造: Start ノード
    // ========================================================================

    /// Start ノードは 25 命令（output.json の index 0..24）。
    @Test
    def testStartNodeInstructionCount(): Unit \ Assert =
        let loaded = TestYarnFixture.loadProject();
        let start = match Map.get("Start", loaded#program#nodes) {
            case Some(node) => node
            case None       => bug!("Start node missing")
        };
        Assert.assertEq(expected = 25, Vector.length(start#instructions))

    /// Start ノードの先頭命令は `runLine "line:9110649c" 0` である。
    @Test
    def testStartNodeFirstInstruction(): Unit \ Assert =
        let loaded = TestYarnFixture.loadProject();
        let start = match Map.get("Start", loaded#program#nodes) {
            case Some(node) => node
            case None       => bug!("Start node missing")
        };
        let first = match Vector.nth(0, start#instructions) {
            case Some(instruction) => instruction
            case None              => bug!("Start has no instructions")
        };
        Assert.assertEq(expected = RunLine("line:9110649c", 0), first)

    /// 最終命令は Return。
    @Test
    def testStartNodeLastInstruction(): Unit \ Assert =
        let loaded = TestYarnFixture.loadProject();
        let start = match Map.get("Start", loaded#program#nodes) {
            case Some(node) => node
            case None       => bug!("Start node missing")
        };
        let last = match Vector.nth(24, start#instructions) {
            case Some(instruction) => instruction
            case None              => bug!("Start has fewer than 25 instructions")
        };
        Assert.assertEq(expected = Return, last)

    // ========================================================================
    // 構造: 初期値
    // ========================================================================

    /// `$straight_yes` は false、`$hp` は 0.0、`$Yarn.Internal.Visiting.Start` は 0.0。
    /// 3 種類の Value バリアント（Bool/Float/未使用 String）の混在を一度に確認する。
    @Test
    def testInitialValuesMixed(): Unit \ Assert =
        let loaded = TestYarnFixture.loadProject();
        let actual = (
            Map.get("\$straight_yes", loaded#program#initialValues),
            Map.get("\$hp", loaded#program#initialValues),
            Map.get("\$Yarn.Internal.Visiting.Start", loaded#program#initialValues)
        );
        let expected = (Some(BoolV(false)), Some(FloatV(0.0)), Some(FloatV(0.0)));
        Assert.assertEq(expected = expected, actual)

    // ========================================================================
    // 失敗ケース
    // ========================================================================

    /// 文字列がそもそも JSON でないとき `JsonParseError` が返る。
    @Test
    def testParseInvalidJson(): Unit \ Assert =
        match Yarn.Loader.parseProject("not json {") {
            case Err(YarnLoadError.JsonParseError(_)) => Assert.assertTrue(true)
            case _                                    => bug!("expected JsonParseError")
        }

    /// 命令キーが未知のとき `UnknownInstruction` が返る。
    /// program 構造は最小限に詰めて、命令だけ存在しないキー `someBadOpcode` にする。
    @Test
    def testParseUnknownInstruction(): Unit \ Assert =
        let json =
            "{\"program\":{\"name\":\"\","
              + "\"nodes\":{\"X\":{\"name\":\"X\",\"headers\":[],"
              + "\"instructions\":[{\"someBadOpcode\":{}}]}},"
              + "\"initialValues\":{},\"languageVersion\":4},"
              + "\"strings\":{}}";
        match Yarn.Loader.parseProject(json) {
            case Err(YarnLoadError.UnknownInstruction(name)) =>
                Assert.assertEq(expected = "someBadOpcode", name)
            case _ =>
                bug!("expected UnknownInstruction")
        }
}
