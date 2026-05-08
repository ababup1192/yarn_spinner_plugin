/// `<<save N>>` / `<<load N>>` 用のセーブファイル I/O。
///
/// 「現在ノード名 + 全変数」だけを `saves/slot{N}.json` に書き、
/// `read` で同じスロット番号から取り戻す。フォーマットは
/// `yarn/output.json` の `initialValues` と同じ Value 表現
/// （`{"boolValue":..}` / `{"floatValue":..}` / `{"stringValue":..}`）。
///
/// CommandRouter 配線は Phase C で別途行う。本モジュールは
/// 単独でも `Fs.FileWrite` / `Fs.FileRead` 効果を持つ呼び出し元から
/// 使えば動く。
mod Game.SaveManager {
    import java.math.{BigDecimal => JBigDecimal}

    use Yarn.Types.Value
    use Yarn.Types.Value.{BoolV, FloatV, StringV}
    use Json.JsonElement
    use Json.JsonElement.{JsonObject, JsonString, JsonNumber, JsonBool}

    /// セーブファイル 1 つ分の中身。`(nodeName, variables)` の tuple を 1 ケース
    /// enum に包む。Flix の record は Eq derive 不可なので位置引数で持つ。
    /// アクセサ `nodeName` / `variables` を別途公開する。
    pub enum SaveData with Eq, ToString {
        case SaveData(String, Map[String, Value])
    }

    /// `SaveData` の `nodeName` を取り出す。
    pub def nodeName(data: SaveData): String =
        let SaveData.SaveData(name, _) = data;
        name

    /// `SaveData` の `variables` を取り出す。
    pub def variables(data: SaveData): Map[String, Value] =
        let SaveData.SaveData(_, vars) = data;
        vars

    /// `saves/slot{N}.json` のパス。
    pub def slotPath(slot: Int32): String = "saves/slot${slot}.json"

    // ════════════════════════════════════════════════════════════════════════
    // 公開 API
    // ════════════════════════════════════════════════════════════════════════

    /// セーブデータを `saves/slot{N}.json` に書き出す。
    /// 親ディレクトリ `saves/` の作成は呼び出し側（または devbox init_hook）で
    /// 行う前提（`Fs.WriteFile` は親ディレクトリを自動作成しない）。
    /// 失敗時は `Err(message)` を返す（呼び出し側で握り潰すかログに出すかを決める）。
    pub def write(slot: Int32, data: SaveData): Result[String, Unit] \ Fs.FileWrite =
        let path = slotPath(slot);
        let json = encodeSaveData(data);
        let pretty = Json.Write.toPrettyString(2, json);
        let result = run {
            Fs.WriteFile.write({str = pretty}, path)
        } with Fs.WriteFile.runWithFileWrite;
        match result {
            case Ok(_)      => Ok(())
            case Err(error) => Err("save write failed: ${error}")
        }

    /// セーブデータを `saves/slot{N}.json` から読む。
    /// ファイルが存在しないか、読み取り／パース失敗なら `None`。
    /// 復元処理（Session.restart 呼び出し）は呼び出し側の責務。
    pub def read(slot: Int32): Option[SaveData] \ Fs.FileRead =
        let readResult = run {
            Fs.ReadFile.read(slotPath(slot))
        } with Fs.ReadFile.runWithFileRead;
        readResult
            |> Result.toOption
            |> Option.flatMap(Json.Parse.parse)
            |> Option.flatMap(decodeSaveData)

    // ════════════════════════════════════════════════════════════════════════
    // エンコーダ
    // ════════════════════════════════════════════════════════════════════════

    /// `SaveData` → `JsonElement`。`{"node":..., "variables":{...}}`。
    def encodeSaveData(data: SaveData): JsonElement =
        let SaveData.SaveData(name, vars) = data;
        let variablesJson = vars
            |> Map.foldLeftWithKey((acc, varName, value) ->
                Map.insert(varName, encodeValue(value), acc),
                Map.empty());
        JsonObject(Map#{
            "node"      => JsonString(name),
            "variables" => JsonObject(variablesJson)
        })

    /// `Value` → `{"boolValue"|"floatValue"|"stringValue": ...}`。
    /// `output.json` の `initialValues` と同じ表現。
    def encodeValue(value: Value): JsonElement = match value {
        case BoolV(b)   => JsonObject(Map#{"boolValue"   => JsonBool(b)})
        case FloatV(n)  => JsonObject(Map#{"floatValue"  => JsonNumber(floatToBd(n))})
        case StringV(s) => JsonObject(Map#{"stringValue" => JsonString(s)})
    }

    /// Float64 → BigDecimal。整数値の trailing zero を取り除いて
    /// `100` (not `100.0`) として書き出す。`output.json` の `initialValues` と同じ書式。
    /// `stripTrailingZeros` 単体だと `50.0` が `5E+1`（scale=-1）になって
    /// 科学技術表記で書かれてしまうので、scale が負なら 0 に戻して
    /// プレーン整数として `50` と書けるようにする。
    /// Java の `BigDecimal.valueOf` を使うため import を `JBigDecimal` で別名化、
    /// 読み込み側の Flix stdlib `BigDecimal` 名前空間と衝突しないようにしている。
    def floatToBd(value: Float64): BigDecimal =
        unsafe IO {
            let stripped = JBigDecimal.valueOf(value).stripTrailingZeros();
            if (stripped.scale() < 0) stripped.setScale(0) else stripped
        }

    // ════════════════════════════════════════════════════════════════════════
    // デコーダ
    // ════════════════════════════════════════════════════════════════════════

    /// `JsonElement` → `Option[SaveData]`。形式不一致は `None`。
    /// forM で「全部 Some なら Some(SaveData)、ひとつでも None なら None」を平らに表現。
    def decodeSaveData(element: JsonElement): Option[SaveData] =
        forM (
            top      <- expectObject(element);
            nodeJson <- Map.get("node", top);
            varsJson <- Map.get("variables", top);
            node     <- expectString(nodeJson);
            varsMap  <- expectObject(varsJson);
            vars     <- traverseVariables(varsMap)
        ) yield SaveData.SaveData(node, vars)

    /// `Map[String, JsonElement]` の全要素を `decodeValue` に通す。
    /// 1 つでも失敗したら全体 `None`。foldLeftWithKey で `Option` を畳む。
    def traverseVariables(map: Map[String, JsonElement]):
                           Option[Map[String, Value]] =
        Map.foldLeftWithKey((acc, name, json) ->
            Option.flatMap(soFar ->
                decodeValue(json) |> Option.map(v -> Map.insert(name, v, soFar)),
                acc),
            Some(Map.empty()),
            map)

    /// 1 変数値の JSON → `Value`。`{kind: payload}` の単一キー判別を
    /// `expectObject |> singleEntry |> matchValueKind` の 3 段パイプで表現。
    def decodeValue(element: JsonElement): Option[Value] =
        expectObject(element)
            |> Option.flatMap(singleEntry)
            |> Option.flatMap(matchValueKind)

    /// `Map` がちょうど 1 エントリなら `(key, value)` を返す。それ以外は `None`。
    def singleEntry(map: Map[String, JsonElement]):
                     Option[(String, JsonElement)] =
        match Map.toList(map) {
            case head :: Nil => Some(head)
            case _           => None
        }

    /// `(kind, payload)` を `Value` のいずれかに対応付ける。
    /// `floatValue` は `tryToFloat64` の None をそのまま伝播させる
    /// （壊れた数値で 0.0 にフォールバックしない）。
    def matchValueKind(pair: (String, JsonElement)): Option[Value] =
        match pair {
            case ("boolValue",   JsonBool(b))   => Some(BoolV(b))
            case ("floatValue",  JsonNumber(n)) =>
                BigDecimal.tryToFloat64(n) |> Option.map(FloatV)
            case ("stringValue", JsonString(s)) => Some(StringV(s))
            case _                               => None
        }

    /// `JsonObject` なら中身の Map を、それ以外は `None`。
    def expectObject(element: JsonElement): Option[Map[String, JsonElement]] =
        match element {
            case JsonObject(map) => Some(map)
            case _               => None
        }

    /// `JsonString` なら中身の文字列、それ以外は `None`。
    def expectString(element: JsonElement): Option[String] =
        match element {
            case JsonString(text) => Some(text)
            case _                => None
        }
}
