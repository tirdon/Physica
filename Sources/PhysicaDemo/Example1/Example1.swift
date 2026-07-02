// Example1 — a standalone wasm executable for the pendulum animation demo.
// The framework lives in Sources/Physica; this target is the visual test host
// for example1.html (renderer, DOM glue, pendulum demo scene).
//
// Build its bundle:
//   swift package --swift-sdk 6.3-SNAPSHOT-2026-06-11-a-wasm32-unknown-wasip1-threads \
//     --allow-writing-to-directory js-example1 js --use-cdn \
//     --output js-example1 --product Example1
// then serve with `bun bunserver.js` and open /example1.html.
//
// The Bun smoke test runs this path with no DOM (→ pendulum path, byte-identical).

#if os(WASI)
import JavaScriptKit
import JavaScriptEventLoop
import Physica

@main
struct Example1App {
    // Retained for the lifetime of the page so the rAF loop / listeners stay live.
    @MainActor static var runtime: WebRuntime?

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
            _ = console.warn("Example1: font unavailable —", String(describing: error))
        }

        var formula: TextEntity?
        do {
            formula = try await MathJaxLoader.formula(
                "\\ddot{\\theta} = -\\frac{g}{\\ell}\\,\\sin\\theta", fontSize: 0.75
            )
        } catch {
            _ = console.warn("Example1: MathJax unavailable —", String(describing: error))
        }

        let engine = Engine()
        let scene = engine.makeScene(name: "pendulum") { scene in
            PendulumDemo.build(scene, font: font, formula: formula)
        }
        runtime = await WebRuntime.run(engine: engine, scene: scene)
    }
}

#else

@main
struct Example1App {
    static func main() {
        print("Example1 is the wasm entry point; build with:")
        print("swift package --swift-sdk 6.3-SNAPSHOT-2026-06-11-a-wasm32-unknown-wasip1-threads --allow-writing-to-directory js-example1 js --use-cdn --output js-example1 --product Example1")
    }
}

#endif
