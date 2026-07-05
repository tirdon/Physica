// Example3 — a Medium-style scientific article rendered straight into the
// browser DOM, styled by example3.html (CSS adapted from the reference page).
// It is the fourth standalone wasm executable; unlike the others it renders no
// WebGPU scene at all — just typeset prose, math, a procedure float, a table,
// and a Reveal.js-like presentation deck, all built from a declarative,
// result-builder DSL (the Article* files in PhysicaWeb, Sources/Physica/WASM/Article/)
// and one authored `Document` (HamiltonianArticle.swift, on Physica's own
// rigid-body integrator).
//
// Build its bundle (separate output dir so it doesn't clobber the other demos):
//   swift package --swift-sdk 6.3-SNAPSHOT-2026-06-11-a-wasm32-unknown-wasip1-threads \
//     --allow-writing-to-directory js-example3 js --use-cdn \
//     --output js-example3 --product Example3
// then serve with `bun bunserver.js` and open /example3.html.
//
// The shared code path logs a plain-text outline of the article FIRST (the
// GPU-free / no-DOM smoke run under Bun has no `document` to render into, so it
// prints the outline and exits cleanly) — the same "log the structure first"
// philosophy WebRuntime uses before booting the renderer.

#if os(WASI)
import JavaScriptKit
import JavaScriptEventLoop
import Physica

@main
struct Example3 {
    /// First line of the outline dump — the smoke check greps for this marker.
    static let outlineBanner = "Example3 — article outline"

    /// Retained for the page lifetime: nav closures + the embedded story decks
    /// (each `presentation {}` block is a real Physica Story with its own renderer
    /// and rAF loop, which must stay alive).
    @MainActor static var mount: ArticleMount?

    static func main() {
        JavaScriptEventLoop.installGlobalExecutor()
        Task { @MainActor in
            await boot()
        }
    }

    @MainActor
    static func boot() async {
        let document = HamiltonianArticle.document

        // Log the outline first (also the sole output under the no-DOM Bun smoke).
        for line in ArticleOutline.lines(for: document, banner: outlineBanner) { print(line) }

        // No DOM (headless smoke) → the outline is printed; nothing to render.
        guard JSObject.global.document.object != nil else {
            print("Example3: no DOM — outline printed, exiting.")
            return
        }

        // The face for the embedded story decks' titles (LaTeX's body serif). If it
        // fails, the decks drop titles but still narrate via their captions.
        let font: Font?
        do {
            font = try await FontLoader.loadComputerModern()
        } catch {
            font = nil
            _ = JSObject.global.console.warn("Example3: font unavailable —", String(describing: error))
        }

        mount = await ArticleDOM.render(document, into: "app", font: font)
        await typeset()
    }

    /// Typesets the freshly-built DOM once MathJax (loaded async by the shell) is
    /// ready. Guarded end to end: if MathJax never arrives, the TeX simply stays
    /// as literal text rather than crashing the page.
    @MainActor
    static func typeset() async {
        let global = JSObject.global

        // Poll for MathJax + its startup.promise (the shell injects it with
        // `async`, so it may still be loading when we finish building the DOM).
        var waited = 0
        var mathJax: JSObject? = nil
        while true {
            if let mj = global.MathJax.object, mj.startup.object != nil,
               mj.startup.promise.object != nil {
                mathJax = mj
                break
            }
            waited += 1
            guard waited < 240 else {
                _ = global.console.warn("Example3: MathJax unavailable — formulas left as TeX.")
                return
            }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }

        guard let mj = mathJax else { return }
        if let startup = mj.startup.promise.object {
            _ = try? await JSPromise(unsafelyWrapping: startup).value()
        }
        // MathJax.typesetPromise() returns a promise; await it so a caller could
        // chain, and so errors surface rather than dangling.
        if mj.typesetPromise.function != nil {
            let result = mj.typesetPromise!()
            if let promise = result.object {
                _ = try? await JSPromise(unsafelyWrapping: promise).value()
            }
        }
    }
}

#else

import Physica

@main
struct Example3 {
    /// First line of the outline dump — matches the WASI path's marker.
    static let outlineBanner = "Example3 — article outline"

    static func main() {
        // Host build: the neutral layer compiles and runs, so print the same
        // outline (proof the model + builders type-check off-wasm) plus a hint.
        for line in ArticleOutline.lines(for: HamiltonianArticle.document, banner: outlineBanner) { print(line) }
        print("")
        print("Example3 is a wasm article; build its bundle with:")
        print("swift package --swift-sdk 6.3-SNAPSHOT-2026-06-11-a-wasm32-unknown-wasip1-threads --allow-writing-to-directory js-example3 js --use-cdn --output js-example3 --product Example3")
    }
}

#endif
