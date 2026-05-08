/// `yarn/output.json` をディスクから読み込んでテスト用の `YarnProject` を返す共通ヘルパー。
/// `TestYarnFixture` は古い「Quest」サンプル用にインライン JSON を持っているので、
/// 本物の story.yarn を回したいテストはこちらを経由する。
///
/// このモジュールは story.yarn 固有のテスト用なので `test/game/` に置く
/// （`test/yarn/` 配下は yarn ランタイムそのものの汎用ライブラリテスト）。
///
/// `Fs.FileRead.runWithIO` を直接 `with` するため、呼び出し側のテストは
/// `\ {Assert, IO}` で OK。`devbox run test` は project root から実行されるので
/// 相対パス `yarn/output.json` で届く。
mod TestStoryFixture {

    /// `yarn/output.json` を読んで `YarnProject` を返す。読み込みに失敗したり
    /// JSON が壊れていたら `bug!`（テストを fail させるシグナル）。
    pub def loadProject(): Yarn.Types.YarnProject \ IO =
        let jsonText = run {
            let readResult = run {
                Fs.ReadFile.read("yarn/output.json")
            } with Fs.ReadFile.runWithFileRead;
            readResult |> Result.getWithDefault("")
        } with Fs.FileRead.runWithIO;
        match Yarn.Loader.parseProject(jsonText) {
            case Ok(loaded) => loaded
            case Err(error) => bug!("yarn/output.json parse failed in test: ${error}")
        }
}
