/// 組み込み関数のテスト。
///
/// 訪問カウンタは `$Yarn.Internal.Visiting.<NodeName>` で表現されるという規約を確認する。
mod TestYarnBuiltins {
    use Yarn.Types.Value
    use Yarn.Types.Value.{BoolV, FloatV, StringV}

    /// 訪問前の `visited_count` は 0、`visited` は false。
    /// 同じテストで両方確認する（同じ規約に依存しているため）。
    @Test
    def testVisitedCountBeforeAnyVisit(): Unit \ Assert =
        region rc {
            let storage = Yarn.VariableStorage.init(rc, Map.empty());
            let count = Yarn.Builtins.call("visited_count", StringV("Start") :: Nil, storage);
            let been  = Yarn.Builtins.call("visited", StringV("Start") :: Nil, storage);
            let expectedCount: Result[String, Value] = Ok(FloatV(0.0));
            let expectedBeen: Result[String, Value]  = Ok(BoolV(false));
            Assert.assertEq(expected = (expectedCount, expectedBeen), (count, been))
        }

    /// 訪問カウンタを 1 に立てたあと、`visited_count` = 1、`visited` = true。
    @Test
    def testVisitedCountAfterVisit(): Unit \ Assert =
        region rc {
            let storage = Yarn.VariableStorage.init(rc, Map.empty());
            Yarn.VariableStorage.incrementFloat("\$Yarn.Internal.Visiting.Start", storage);
            let count = Yarn.Builtins.call("visited_count", StringV("Start") :: Nil, storage);
            let been  = Yarn.Builtins.call("visited", StringV("Start") :: Nil, storage);
            let expectedCount: Result[String, Value] = Ok(FloatV(1.0));
            let expectedBeen: Result[String, Value]  = Ok(BoolV(true));
            Assert.assertEq(expected = (expectedCount, expectedBeen), (count, been))
        }

    /// `Number.EqualTo` は等価/非等価で true/false を返す。
    /// 0 == 0 と 0 == 2 を 1 度に確認する。
    @Test
    def testNumberEqualTo(): Unit \ Assert =
        region rc {
            let storage = Yarn.VariableStorage.init(rc, Map.empty());
            let same   = Yarn.Builtins.call(
                "Number.EqualTo", FloatV(0.0) :: FloatV(0.0) :: Nil, storage);
            let differ = Yarn.Builtins.call(
                "Number.EqualTo", FloatV(0.0) :: FloatV(2.0) :: Nil, storage);
            let expectedSame: Result[String, Value]   = Ok(BoolV(true));
            let expectedDiffer: Result[String, Value] = Ok(BoolV(false));
            Assert.assertEq(expected = (expectedSame, expectedDiffer), (same, differ))
        }
}
