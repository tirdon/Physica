// Example2 — the pendulum equation game on the `Storytelling` facade: a
// four-slide scrollytelling story where the viewer resolves forces on a
// mass-on-a-string, drags projection operators onto a vector equation, and
// watches the small-angle approximation animate. The rich story script lives
// in EquationStoryDemo.swift, unchanged from the pre-facade demo.
//
// Build its bundle:
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

// Interactive equation-game story
@main
struct Example2 {
    /// The game wires drop targets/win state and must outlive the mount.
    @MainActor static var game: EquationGame?

    static func main() {
        JavaScriptEventLoop.installGlobalExecutor()
        // The facade mount loads MathJax (and the fonts) before running the
        // story closure, recording the outcome in `Config.mathJaxReady`.
        Storytelling(name: "equation-story", story: { story in
            // Equation tokens render with MathJax when available, otherwise
            // the loaded font, otherwise stub boxes.
            let font = FontBook.resolve(.body).font
            let provider: TokenGlyphProvider = Config.mathJaxReady
                ? MathJaxTokenProvider()
                : (font.map { FontTokenGlyphProvider(font: $0) } ?? StubTokenGlyphProvider())
            game = EquationStoryDemo.build(story, font: font, provider: provider)
        })
    }
}

#else

@main
struct Example2 {
    static func main() {
        print("Example2 is the wasm equation-game story; build with:")
        print("swift package --swift-sdk 6.3-SNAPSHOT-2026-06-11-a-wasm32-unknown-wasip1-threads --allow-writing-to-directory js-example2 js --use-cdn --output js-example2 --product Example2")
    }
}

#endif
