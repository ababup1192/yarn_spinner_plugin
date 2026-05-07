/// Yarn の `callFunc` から呼ばれる組み込み関数群。
///
/// 引数は呼び出し元の VM がスタックから pop した順で渡す（先頭が引数 0、末尾が引数 N-1）。
/// 結果は新しい `Value` を返し、VM がスタックに push する。
///
/// 現状サポート:
///   - `visited(nodeName)`         -> Bool   訪問済みか
///   - `visited_count(nodeName)`   -> Float  訪問回数
///   - `Number.EqualTo(a, b)`      -> Bool   数値等価
///   - `Number.NotEqualTo(a, b)`   -> Bool
///   - `Number.GreaterThan(a, b)`  -> Bool
///   - `Number.LessThan(a, b)`     -> Bool
///   - `Bool.And(a, b)`            -> Bool
///   - `Bool.Or(a, b)`             -> Bool
///   - `Bool.Not(a)`               -> Bool
///
/// 訪問カウンタは `$Yarn.Internal.Visiting.<nodeName>` という変数に格納されている前提。
/// VM の `RunNode` がこれを +1 する（`Yarn.VariableStorage.incrementFloat`）。
mod Yarn.Builtins {
    use Yarn.Types.Value
    use Yarn.Types.Value.{BoolV, FloatV, StringV}
    use Yarn.VariableStorage.VariableStorage

    /// 関数名と引数列を受け取り結果値を返す。エラーメッセージは未対応関数や
    /// 引数の型・個数ミスの理由を含む。
    pub def call(name: String,
                  arguments: List[Value],
                  storage: VariableStorage[r]):
                  Result[String, Value] \ r =
        match (name, arguments) {
            case ("visited", StringV(nodeName) :: Nil) =>
                Ok(BoolV(visitedCountOf(nodeName, storage) > 0.0))

            case ("visited_count", StringV(nodeName) :: Nil) =>
                Ok(FloatV(visitedCountOf(nodeName, storage)))

            case ("Number.EqualTo", FloatV(a) :: FloatV(b) :: Nil) =>
                Ok(BoolV(a == b))

            case ("Number.NotEqualTo", FloatV(a) :: FloatV(b) :: Nil) =>
                Ok(BoolV(a != b))

            case ("Number.GreaterThan", FloatV(a) :: FloatV(b) :: Nil) =>
                Ok(BoolV(a > b))

            case ("Number.LessThan", FloatV(a) :: FloatV(b) :: Nil) =>
                Ok(BoolV(a < b))

            case ("Bool.And", BoolV(a) :: BoolV(b) :: Nil) =>
                Ok(BoolV(a and b))

            case ("Bool.Or", BoolV(a) :: BoolV(b) :: Nil) =>
                Ok(BoolV(a or b))

            case ("Bool.Not", BoolV(a) :: Nil) =>
                Ok(BoolV(not a))

            case _ =>
                Err("unknown or mistyped builtin: ${name} (${List.length(arguments)} args)")
        }

    /// 訪問カウンタ `$Yarn.Internal.Visiting.<nodeName>` を読む。未設定は 0 扱い。
    def visitedCountOf(nodeName: String, storage: VariableStorage[r]): Float64 \ r =
        let key = "\$Yarn.Internal.Visiting.${nodeName}";
        match Yarn.VariableStorage.get(key, storage) {
            case Some(FloatV(n)) => n
            case _               => 0.0
        }
}
