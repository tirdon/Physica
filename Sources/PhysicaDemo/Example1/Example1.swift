// Example1 — the pendulum animation demo on the `Storytelling` facade: one
// statement mounts the scene (fonts, page chrome, renderer, playback, input).
// The rich scene script lives in Demos/PendulumDemo.swift, unchanged from the
// pre-facade demo.
//
// Build its bundle:
//   swift package --swift-sdk 6.3-SNAPSHOT-2026-06-11-a-wasm32-unknown-wasip1-threads \
//     --allow-writing-to-directory js-example1 js --use-cdn \
//     --output js-example1 --product Example1
// then serve with `bun bunserver.js` and open /example1.html.
//
// The Bun smoke test runs this path with no DOM (the timeline still logs).

#if os(WASI)
import JavaScriptKit
import JavaScriptEventLoop
import Physica

// Animation example
@main
struct Example1 {
    static func main() {
        JavaScriptEventLoop.installGlobalExecutor()
        // The facade mount loads fonts + MathJax before running the closure,
        // so the swing-equation formula renders synchronously here; `try?`
        // degrades to nil without MathJax (headless smoke) — the demo skips math.
		Storytelling(name: "pendulum") { scene -> Void in
            let formula = try? MathJaxLoader.formulaNow(
                "\\ddot{\\theta} = -\\frac{g}{\\ell}\\,\\sin\\theta", fontSize: 0.75
            )
            PendulumDemo.build(
                scene, font: FontBook.resolve(.body).font, formula: formula
            )
        }
    }
}

#else

@main
struct Example1 {
    static func main() {
        print("Example1 is the wasm pendulum demo; build with:")
        print("swift package --swift-sdk 6.3-SNAPSHOT-2026-06-11-a-wasm32-unknown-wasip1-threads --allow-writing-to-directory js-example1 js --use-cdn --output js-example1 --product Example1")
    }
}

#endif
