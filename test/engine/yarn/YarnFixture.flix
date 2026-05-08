/// Yarn output.json の内容をテスト用にインライン化したフィクスチャ。
/// ファイルシステム依存を消すため、全テストはこのモジュール経由で
/// `outputJsonText()` を呼ぶ。
mod TestYarnFixture {

    /// `yarn/output.json` の中身を一行 JSON にコンパクト化したもの。
    /// 元データと意味的に同等で、`Yarn.Loader.parseProject` が同じ構造を返す。
    pub def outputJsonText(): String =
        "{\"program\":{\"name\":\"\",\"nodes\":{\"Start\":{\"name\":\"Start\",\"headers\":[{\"key\":\"title\",\"value\":\"Start\"},{\"key\":\"$Yarn.Internal.TrackingVariable\",\"value\":\"$Yarn.Internal.Visiting.Start\"}],\"instructions\":[{\"runLine\":{\"lineID\":\"line:9110649c\",\"substitutionCount\":0}},{\"runLine\":{\"lineID\":\"line:072063eb\",\"substitutionCount\":0}},{\"addOption\":{\"lineID\":\"line:bd716a72\",\"destination\":8,\"substitutionCount\":0,\"hasCondition\":false}},{\"addOption\":{\"lineID\":\"line:88d4099b\",\"destination\":20,\"substitutionCount\":0,\"hasCondition\":false}},{\"showOptions\":{}},{\"jumpIfFalse\":{\"destination\":24}},{\"pop\":{}},{\"peekAndJump\":{}},{\"pop\":{}},{\"pushString\":{\"value\":\"Start\"}},{\"pushFloat\":{\"value\":1}},{\"callFunc\":{\"functionName\":\"visited_count\"}},{\"pushFloat\":{\"value\":0}},{\"pushFloat\":{\"value\":2}},{\"callFunc\":{\"functionName\":\"Number.EqualTo\"}},{\"storeVariable\":{\"variableName\":\"$straight_yes\"}},{\"pop\":{}},{\"runLine\":{\"lineID\":\"line:2b416d05\",\"substitutionCount\":0}},{\"runNode\":{\"nodeName\":\"Quest\"}},{\"jumpTo\":{\"destination\":24}},{\"pop\":{}},{\"runLine\":{\"lineID\":\"line:1ee40eec\",\"substitutionCount\":0}},{\"runNode\":{\"nodeName\":\"Start\"}},{\"jumpTo\":{\"destination\":24}},{\"return\":{}}]},\"Quest\":{\"name\":\"Quest\",\"headers\":[{\"key\":\"title\",\"value\":\"Quest\"}],\"instructions\":[{\"pushVariable\":{\"variableName\":\"$hp\"}},{\"runLine\":{\"lineID\":\"line:7fc00f8b\",\"substitutionCount\":1}},{\"runCommand\":{\"commandText\":\"wait 0.5\",\"substitutionCount\":0}},{\"runLine\":{\"lineID\":\"line:e9f008fc\",\"substitutionCount\":0}},{\"return\":{}}]},\"End\":{\"name\":\"End\",\"headers\":[{\"key\":\"title\",\"value\":\"End\"}],\"instructions\":[{\"runLine\":{\"lineID\":\"line:200f8221\",\"substitutionCount\":0}},{\"return\":{}}]}},\"initialValues\":{\"$straight_yes\":{\"boolValue\":false},\"$hp\":{\"floatValue\":0},\"$Yarn.Internal.Visiting.Start\":{\"floatValue\":0}},\"languageVersion\":4},\"strings\":{\"line:9110649c\":{\"text\":\"おう: ゆうしゃよ、よくぞ もどった！\"},\"line:072063eb\":{\"text\":\"おう: まおうを たおすのじゃ。\"},\"line:bd716a72\":{\"text\":\"はい\"},\"line:2b416d05\":{\"text\":\"おう: たのもしいぞ。\"},\"line:88d4099b\":{\"text\":\"いいえ\"},\"line:1ee40eec\":{\"text\":\"おう: …なさけないやつめ。\"},\"line:7fc00f8b\":{\"text\":\"おう: ＨＰは {0} ある。 きをつけてゆけ！\"},\"line:e9f008fc\":{\"text\":\"おう: …では、たびだちじゃ。\"},\"line:200f8221\":{\"text\":\"おう: また あおう。\"}},\"diagnostics\":[]}"

    /// fixture を parse して `YarnProject` に変換する共通ヘルパー。
    pub def loadProject(): Yarn.Types.YarnProject =
        match Yarn.Loader.parseProject(outputJsonText()) {
            case Ok(loaded)  => loaded
            case Err(_)      => bug!("inline fixture failed to parse")
        }
}
