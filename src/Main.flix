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
            // PixelMplus10 は 10px 設計のドットフォント。bake サイズも 10 に揃える。
            // [b] タグ用に Bold バリアントを並列登録し、RichTextLabel が文字単位で
            // 切り替える（DialogueScene が `default` と `default-bold` の両方を
            // getFontAtlas して RichTextLabel に注入する）。
            fontManifest    =
                ({ name = "default",      path = "fonts/PixelMplus10-Regular.ttf", fontSize = 10.0 }: GameEngine.FontEntry)
                :: ({ name = "default-bold", path = "fonts/PixelMplus10-Bold.ttf",    fontSize = 10.0 }: GameEngine.FontEntry)
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
            Game.start()
        } with LwjglLayer.withLwjgl(config)
          with Fs.FileRead.runWithIO
          with Fs.FileWrite.runWithIO
          with Fs.Glob.runWithIO
          with Fs.ModificationTime.runWithFileTime
          with Fs.FileTime.runWithIO
          with Math.Random.runWithIO
    }
