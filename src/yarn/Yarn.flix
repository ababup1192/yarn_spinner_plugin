/// 公開ファサード。
///
/// エンジン層・対話層が `Yarn` 経由で内部モジュールへアクセスする際の入口。
/// 直接 `Yarn.Loader` 等を `use` しても良いが、ここに集めると見通しが良い。
mod Yarn {
    use Yarn.Types.YarnProject
    use Yarn.Types.Value
    use Yarn.Types.Value.{FloatV}

    /// 既存 `YarnProject` の `initialValues` で 1 つの変数だけ上書きした
    /// 新しい `YarnProject` を返す。
    ///
    /// 用途: ゲーム起動時に外部から HP などの初期値を注入したいとき、
    /// `Yarn.Loader.parseProject` で得た project を VM に渡す前に当てる。
    /// 変更は純粋（元の project は変えない）。
    /// 注意: Flix では `project` は予約語のため、引数名は `loaded` を採用している。
    pub def overrideInitialFloat(name: String, value: Float64, loaded: YarnProject):
                                  YarnProject =
        let newInitial =
            Map.insert(name, FloatV(value), loaded#program#initialValues);
        let newProgram = { initialValues = newInitial | loaded#program };
        { program = newProgram | loaded }
}
