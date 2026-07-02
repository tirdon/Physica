// Example2 — a standalone Physica *story* (slide mode): the pendulum equation
// game. A four-slide scrollytelling demo where the viewer resolves forces on a
// mass-on-a-string, drags projection operators onto a vector equation, and
// watches the small-angle approximation animate. See EquationStoryDemo.swift for
// the scene script.
//
// Build its bundle (separate output dir so it doesn't clobber other examples):
//   swift package --swift-sdk 6.3-SNAPSHOT-2026-06-11-a-wasm32-unknown-wasip1-threads \
//     --allow-writing-to-directory js-example2 js --use-cdn \
//     --output js-example2 --product Example2
// then serve with `bun bunserver.js` and open /example2.html.
//
// Everything degrades: no font → no labels; no MathJax → stub/font token glyphs.

#if os(WASI)
import JavaScriptKit
import JavaScriptEventLoop
import Physica

@main
struct Example2App {
    // Retained for the lifetime of the page so the rAF loop / listeners stay live.
    @MainActor static var runtime: StoryRuntime?
    @MainActor static var game: EquationGame?

    static func main() {
        JavaScriptEventLoop.installGlobalExecutor()
        Task { @MainActor in
            await boot()
        }
    }

    @MainActor
    static func boot() async {
        let console = JSObject.global.console

        let font: Font?
        do {
            font = try await FontLoader.load()
        } catch {
            font = nil
            _ = console.warn("Example2: font unavailable —", String(describing: error))
        }

        // Equation tokens render with MathJax when available, otherwise a font,
        // otherwise stub boxes — the story still works, just less pretty.
        let provider: TokenGlyphProvider
        do {
            try await MathJaxLoader.load()
            provider = MathJaxTokenProvider()
        } catch {
            _ = console.warn("Example2: MathJax unavailable —", String(describing: error))
            provider = font.map { FontTokenGlyphProvider(font: $0) } ?? StubTokenGlyphProvider()
        }

        let engine = Engine()
        let scene = engine.makeScene(name: "equation-story") { _ in }
        let story = Story(scene: scene)
        game = EquationStoryDemo.build(story, font: font, provider: provider)
        runtime = await StoryRuntime.run(engine: engine, story: story)
    }
}

#else

@main
struct Example2App {
    static func main() {
        print("Example2 is a wasm story; build with:")
        print("swift package --swift-sdk 6.3-SNAPSHOT-2026-06-11-a-wasm32-unknown-wasip1-threads --allow-writing-to-directory js-example2 js --use-cdn --output js-example2 --product Example2")
    }
}

#endif
