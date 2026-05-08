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

    /// `Number.Add` / `Number.Minus` は四則の和差を返す。ysc は `+` を Add に、
    /// `-` を **Subtract ではなく Minus** に降ろす点に注意。
    @Test
    def testNumberAddAndMinus(): Unit \ Assert =
        region rc {
            let storage = Yarn.VariableStorage.init(rc, Map.empty());
            let added   = Yarn.Builtins.call(
                "Number.Add", FloatV(7.0) :: FloatV(3.0) :: Nil, storage);
            let minused = Yarn.Builtins.call(
                "Number.Minus", FloatV(100.0) :: FloatV(25.0) :: Nil, storage);
            let expectedAdd: Result[String, Value]   = Ok(FloatV(10.0));
            let expectedMinus: Result[String, Value] = Ok(FloatV(75.0));
            Assert.assertEq(expected = (expectedAdd, expectedMinus), (added, minused))
        }

    /// `Number.LessThanOrEqualTo` / `Number.GreaterThanOrEqualTo` の境界値挙動。
    /// 同値で true、片側で false を 1 ケースで確認する。
    @Test
    def testNumberOrEqualBoundaries(): Unit \ Assert =
        region rc {
            let storage = Yarn.VariableStorage.init(rc, Map.empty());
            let leEq = Yarn.Builtins.call(
                "Number.LessThanOrEqualTo", FloatV(5.0) :: FloatV(5.0) :: Nil, storage);
            let leGt = Yarn.Builtins.call(
                "Number.LessThanOrEqualTo", FloatV(6.0) :: FloatV(5.0) :: Nil, storage);
            let geEq = Yarn.Builtins.call(
                "Number.GreaterThanOrEqualTo", FloatV(5.0) :: FloatV(5.0) :: Nil, storage);
            let geLt = Yarn.Builtins.call(
                "Number.GreaterThanOrEqualTo", FloatV(4.0) :: FloatV(5.0) :: Nil, storage);
            let expected: (Result[String, Value], Result[String, Value],
                           Result[String, Value], Result[String, Value]) =
                (Ok(BoolV(true)), Ok(BoolV(false)), Ok(BoolV(true)), Ok(BoolV(false)));
            Assert.assertEq(expected = expected, (leEq, leGt, geEq, geLt))
        }

    /// `has_item` は `$inv_<itemId>` の Bool を読む規約。
    /// 未設定は false、true を立てたら true、false を立てたら false。
    @Test
    def testHasItemFollowsInvVariable(): Unit \ Assert =
        region rc {
            let storage = Yarn.VariableStorage.init(rc, Map.empty());
            let before = Yarn.Builtins.call(
                "has_item", StringV("key") :: Nil, storage);
            Yarn.VariableStorage.set("\$inv_key", BoolV(true), storage);
            let after  = Yarn.Builtins.call(
                "has_item", StringV("key") :: Nil, storage);
            Yarn.VariableStorage.set("\$inv_key", BoolV(false), storage);
            let dropped = Yarn.Builtins.call(
                "has_item", StringV("key") :: Nil, storage);
            let expected: (Result[String, Value], Result[String, Value],
                           Result[String, Value]) =
                (Ok(BoolV(false)), Ok(BoolV(true)), Ok(BoolV(false)));
            Assert.assertEq(expected = expected, (before, after, dropped))
        }
}
