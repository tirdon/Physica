// Loads MathJax (tex-svg component) from the CDN and renders TeX → SVG
// markup, which MathSVG turns into glyph paths. DOM-only: headless smoke
// (Bun, no document) bails out with .unavailable and the demo skips math.

#if os(WASI)
import JavaScriptKit
import JavaScriptEventLoop

enum MathJaxError: Error {
    case unavailable          // no DOM (headless) — not a failure, just absent
    case loadTimeout
    case renderFailed(String)
}

@MainActor
public enum MathJaxLoader {
    static let scriptURL = "https://cdn.jsdelivr.net/npm/mathjax@3.2.2/es5/tex-svg.js"

    private static var isReady = false

    /// Inject the MathJax script (crossorigin — jsDelivr sends CORS headers,
    /// required under our COEP) and await its startup promise. Public so the
    /// story runtime can resolve it once at boot, then render tokens synchronously.
    public static func load() async throws {
        if isReady { return }
        let global = JSObject.global
        guard let document = global.document.object, document.head.object != nil else {
            throw MathJaxError.unavailable
        }

        // Configure before the script evaluates. fontCache "local" keeps every
        // glyph <path> inside its own <svg> — MathSVG resolves <use> from there.
        let svgConfig: [String: JSValue] = ["fontCache": .string("local")]
        let startupConfig: [String: JSValue] = ["typeset": .boolean(false)]
        let config: [String: JSValue] = [
            "svg": svgConfig.jsValue, "startup": startupConfig.jsValue,
        ]
        global.MathJax = config.jsValue

        var script = document.createElement!("script")
        script.src = .string(scriptURL)
        script.crossOrigin = .string("anonymous")
        _ = document.head.appendChild(script)

        // The script defines window.MathJax.startup once evaluated; its
        // promise resolves when the TeX input jax is ready. Poll for arrival
        // (cheap, avoids JSClosure-retention dances for a one-shot load).
        var waited = 0
        while startupPromise() == nil {
            waited += 1
            guard waited < 300 else { throw MathJaxError.loadTimeout }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        _ = try await JSPromise(unsafelyWrapping: startupPromise()!).value()
        isReady = true
    }

    /// TeX → the outer HTML of MathJax's <svg> (display style). Synchronous once
    /// `load()` has resolved — the per-token glyph provider relies on this.
    public static func svg(for tex: String) throws -> String {
        guard isReady, let mathJax = JSObject.global.MathJax.object else {
            throw MathJaxError.renderFailed(tex)
        }
        let container = mathJax.tex2svg!(tex)
        let svg = container.querySelector("svg")
        guard let markup = svg.outerHTML.string else {
            throw MathJaxError.renderFailed(tex)
        }
        return markup
    }

    /// One-call convenience: TeX → centered formula entity.
    public static func formula(
        _ tex: String, fontSize: Real = 1, color: Color = .white
    ) async throws -> TextEntity {
        try await load()
        return try TextEntity.math(
            svg: svg(for: tex), fontSize: fontSize, color: color, named: tex
        )
    }

    private static func startupPromise() -> JSObject? {
        guard let mathJax = JSObject.global.MathJax.object,
            let startup = mathJax.startup.object
        else { return nil }
        return startup.promise.object
    }
}
#endif
