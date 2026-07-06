// Example0 — the "Finite Difference Solvers for Wave Interference" story on
// the `Storytelling` facade: one statement mounts the five-slide
// scrollytelling explainer (fonts, page chrome, renderer, scroll-scrub,
// captions). The rich story script lives in WaveStory.swift, unchanged from
// the pre-facade demo.
//
// Build its bundle:
//   swift package --swift-sdk 6.3-SNAPSHOT-2026-06-11-a-wasm32-unknown-wasip1-threads \
//     --allow-writing-to-directory js-example0 js --use-cdn \
//     --output js-example0 --product Example0
// then serve with `bun bunserver.js` and open /example0.html.
//
// Everything degrades: no font → captions still narrate; no MathJax → the
// inline formulas drop but the geometry and captions carry the story.

#if os(WASI)
import JavaScriptKit
import JavaScriptEventLoop
import Physica

// Interactive presentation slide example
@main
struct Example0 {
    static func main() {
        JavaScriptEventLoop.installGlobalExecutor()
        Task { @MainActor in
            let formulas = await loadFormulas()

            Storytelling(name: "wave-interference", story: { story in
                // The facade loaded the default faces before this runs.
                WaveStory.build(story, font: FontBook.resolve(.body).font, formulas: formulas)
            })
        }
    }

    /// Renders the slides' formulas with MathJax once it is loaded. Each `try?`
    /// leaves its field `nil` on failure, and a failed `load()` skips them all —
    /// `WaveStory` then leans on captions alone.
    @MainActor
    private static func loadFormulas() async -> WaveStory.Formulas {
        let console = JSObject.global.console
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
        print("Example0 is the wasm wave story; build with:")
        print("swift package --swift-sdk 6.3-SNAPSHOT-2026-06-11-a-wasm32-unknown-wasip1-threads --allow-writing-to-directory js-example0 js --use-cdn --output js-example0 --product Example0")
    }
}

#endif
