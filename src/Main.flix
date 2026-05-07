def main(): Unit \ {IO, Chan, NonDet} =
    if (GameEngine.ensureMainThread()) ()
    else {
        let config: GameEngine.EngineConfig = {
            designWidth     = Game.designWi(),
            designHeight    = Game.designHi(),
            windowWidth     = Game.windowWi(),
            windowHeight    = Game.windowHi(),
            title           = "Yarn Spinner Plugin",
            textureManifest = Nil,
            // BestTen-DOT は 16px 単位の dot 字形なので bake サイズも 16 に揃える。
            // 12 など中途半端な値で bake するとグリフが崩れて滲んで見える。
            fontManifest    =
                ({ name = "default", path = "fonts/BestTen-DOT.otf", fontSize = 16.0 }: GameEngine.FontEntry)
                :: Nil,
            // talk: 行が出るたびに頭の 1〜2 秒（自然減衰まで）を流す効果音
            // tap : 確定キーで会話が進むタイミングの効果音
            soundManifest   =
                ({ name = "talk", path = "audio/talk.ogg", looping = false }: GameEngine.AudioEntry)
                :: ({ name = "tap",  path = "audio/tap.ogg",  looping = false }: GameEngine.AudioEntry)
                :: Nil,
            clearColor      = {r = 0.1f32, g = 0.1f32, b = 0.15f32},
            maxDeltaTime    = 0.05
        };
        run {
            // ゆうしゃの HP は外から注入（fixture デフォルトの 0 を上書き）。
            Game.start(15)
        } with LwjglLayer.withLwjgl(config)
          with Fs.FileRead.runWithIO
          with Fs.FileWrite.runWithIO
          with Fs.Glob.runWithIO
          with Fs.ModificationTime.runWithFileTime
          with Fs.FileTime.runWithIO
          with Math.Random.runWithIO
    }
