// Example0 — a standalone Physica *story* (slide mode), compiled to its own wasm
// bundle. It scripts the paper "Finite Difference Solvers for Wave Interference"
// as a five-slide scrollytelling explainer (see WaveStory.swift). This file is the
// thin wasm entry point: load the font, pre-render the MathJax formulas, build the
// Story, and hand it to `StoryRuntime` — the mirror of the demo's story boot.
//
// Build its bundle (separate output dir so it doesn't clobber the demo's js/):
//   swift package --swift-sdk 6.3-RELEASE-wasm32-unknown-wasip1-threads \
//     --allow-writing-to-directory js-example0 js --use-cdn \
//     --output js-example0 --product Example0
// then serve with `bun bunserver.js` and open /example0.html.
//
// Everything degrades: no font → captions still narrate; no MathJax → the inline
// formulas drop but the geometry and captions carry the story.

#if os(WASI)
import JavaScriptKit
import JavaScriptEventLoop
import Physica

@main
struct Example0 {
    // Retained for the lifetime of the page so the rAF loop / listeners stay live.
    @MainActor static var runtime: StoryRuntime?

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
            _ = console.warn("Example0: font unavailable —", String(describing: error))
        }

        let formulas = await loadFormulas(console: console)

        let engine = Engine()
        let scene = engine.makeScene(name: "wave-interference") { _ in }
        let story = Story(scene: scene)
        WaveStory.build(story, font: font, formulas: formulas)
        runtime = await StoryRuntime.run(engine: engine, story: story)
    }

    /// Renders the slides' formulas with MathJax once it is loaded. Each `try?`
    /// leaves its field `nil` on failure, and a failed `load()` skips them all —
    /// `WaveStory` then leans on captions alone.
    @MainActor
    private static func loadFormulas(console: JSValue) async -> WaveStory.Formulas {
        var formulas = WaveStory.Formulas()
        do {
            try await MathJaxLoader.load()
        } catch {
            _ = console.warn("Example0: MathJax unavailable — formulas skipped:", String(describing: error))
            return formulas
        }

        formulas.wave1D = try? await MathJaxLoader.formula(
            "u_{tt} = c^{2}\\,u_{xx}", fontSize: 0.55, color: WaveStory.chalk)
        formulas.update1D = try? await MathJaxLoader.formula(
            "u_i^{\\,n+1} = 2u_i^{\\,n} - u_i^{\\,n-1} + r^{2}\\!\\left(u_{i+1}^{\\,n} - 2u_i^{\\,n} + u_{i-1}^{\\,n}\\right)",
            fontSize: 0.42, color: WaveStory.chalk)
        formulas.courant1D = try? await MathJaxLoader.formula(
            "r = \\dfrac{c\\,\\Delta t}{\\Delta x} \\le 1", fontSize: 0.5, color: WaveStory.chalk)
        formulas.wave2D = try? await MathJaxLoader.formula(
            "u_{tt} = c^{2}\\,(u_{xx} + u_{yy}) - \\gamma\\,u_t", fontSize: 0.5, color: WaveStory.chalk)
        formulas.courant2D = try? await MathJaxLoader.formula(
            "r \\le \\dfrac{1}{\\sqrt{2}}", fontSize: 0.5, color: WaveStory.chalk)
        formulas.constructive = try? await MathJaxLoader.formula(
            "r_2 - r_1 = m\\lambda", fontSize: 0.42, color: WaveStory.warm)
        formulas.destructive = try? await MathJaxLoader.formula(
            "r_2 - r_1 = \\left(m + \\tfrac{1}{2}\\right)\\lambda", fontSize: 0.42, color: WaveStory.danger)
        return formulas
    }
}

#else

@main
struct Example0 {
    static func main() {
        print("Example0 is a wasm story; build with:")
        print("swift package --swift-sdk 6.3-RELEASE-wasm32-unknown-wasip1-threads --allow-writing-to-directory js-example0 js --use-cdn --output js-example0 --product Example0")
    }
}

#endif
