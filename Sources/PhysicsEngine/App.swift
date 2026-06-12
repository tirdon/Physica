// App — load resources, build the demo scene, hand it to the framework shell.

#if os(WASI)
import JavaScriptKit
import Physica

@MainActor
enum App {
    static var runtime: WebRuntime?

    static func boot() async {
        let console = JSObject.global.console

        // Fonts come over the network; the scene must still build without one.
        let font: Font?
        do {
            font = try await FontLoader.load()
        } catch {
            font = nil
            _ = console.warn("Physica: font unavailable —", String(describing: error))
        }

        // Same deal for MathJax (needs DOM + CDN): the demo skips math without it.
        var formula: TextEntity?
        do {
            formula = try await MathJaxLoader.formula(
                "\\ddot{\\theta} = -\\frac{g}{\\ell}\\,\\sin\\theta", fontSize: 0.75
            )
        } catch {
            _ = console.warn("Physica: MathJax unavailable —", String(describing: error))
        }

        // Build the scene script first — it must work without a GPU (headless smoke).
        let engine = Engine()
        let scene = engine.makeScene(name: "pendulum") { scene in
            PendulumDemo.build(scene, font: font, formula: formula)
        }

        runtime = await WebRuntime.run(engine: engine, scene: scene)
    }
}
#endif
