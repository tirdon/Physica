// DocumentAutoMount — the article counterpart of `Storytelling`: the machinery
// behind the `Document("title") { … }` facade spelling. Lifts the pre-facade
// Example3 boot wholesale: log the outline first (the GPU-free smoke's only
// output), bail without a DOM, otherwise inject MathJax + a mount host, walk
// the document with `ArticleDOM`, and typeset. The mount is parked in
// `FacadeRoots` (nav closures + embedded story decks own rAF loops).

import PhysicaFoundation
import PhysicaAlgebra
import PhysicaTypesetting
import PhysicaKernel
import PhysicaCharts
import PhysicaPhysics
import PhysicaEquationGame
import PhysicaArticle

#if os(WASI)
import JavaScriptKit
import JavaScriptEventLoop   // JSPromise.value() lives there (CLAUDE.md gotcha)

public enum DocumentAutoMount {
    /// Wires `Document.autoMount` to this DOM mounter, so a bare
    /// `Document("title") { … }` statement renders itself. Call once at startup
    /// before building any facade `Document` (the model lives in the JSKit-free
    /// `PhysicaArticle` target and can't name this mounter directly, hence the
    /// hook). Idempotent.
    public static func install() {
        Document.autoMount = { schedule($0) }
    }

    /// Called via the `Document.autoMount` hook (nonisolated); hops to the main actor.
    static func schedule(_ document: Document) {
        Task { @MainActor in
            await mount(document)
        }
    }

    @MainActor
    static func mount(_ document: Document) async {
        // Log the structure first — the no-DOM Bun smoke's whole output.
        let banner = document.title.isEmpty ? "Article outline" : "\(document.title) — article outline"
        for line in ArticleOutline.lines(for: document, banner: banner) { print(line) }

        guard let dom = JSObject.global.document.object else {
            print("Physica: no DOM — outline printed, exiting.")
            return
        }

        if !document.title.isEmpty {
            dom.title = .string(document.title)
        }

        ensureMathJax(dom)
        let hostID = ensureHost(dom)

        // The face for embedded story decks' titles (LaTeX's body serif); decks
        // degrade to captions without it.
        let font: Font?
        do {
            font = try await FontLoader.loadComputerModern()
        } catch {
            font = nil
            _ = JSObject.global.console.warn(
                "Physica: article font unavailable —", String(describing: error)
            )
        }

        let mount = await ArticleDOM.render(document, into: hostID, font: font)
        FacadeRoots.keep(mount)
        await typeset()
    }

    /// The article mount element — an existing `#app` (the pre-facade shells),
    /// else a fresh one appended to `<body>` (the plain shell has none).
    @MainActor
    private static func ensureHost(_ dom: JSObject) -> String {
        let hostID = "app"
        if dom.getElementById!(hostID).object != nil { return hostID }
        var host = dom.createElement!("div")
        host.id = .string(hostID)
        var body = dom.body
        _ = body.appendChild(host)
        return hostID
    }

    /// Injects the MathJax v3 config + CDN script when the page carries neither
    /// (the plain shell). Config must land before the script; `crossorigin` is
    /// required under the dev server's COEP (same reason as the tex-svg loader).
    @MainActor
    private static func ensureMathJax(_ dom: JSObject) {
        guard JSObject.global.MathJax.object == nil else { return }

        let config: JSValue = [
            "tex": [
                "inlineMath": [["\\(", "\\)"], ["$", "$"]].jsValue,
                "displayMath": [["$$", "$$"], ["\\[", "\\]"]].jsValue,
                "tags": "none".jsValue,          // equation numbers placed manually via \tag{N}
                "processEscapes": true.jsValue,
            ].jsValue,
            "chtml": ["mtextInheritFont": true.jsValue].jsValue,  // \text uses the page serif
            "options": [
                "skipHtmlTags": ["script", "noscript", "style", "textarea", "pre", "code"].jsValue,
            ].jsValue,
        ].jsValue
        JSObject.global.MathJax = config

        var script = dom.createElement!("script")
        _ = script.setAttribute("src", "https://cdn.jsdelivr.net/npm/mathjax@3/es5/tex-mml-chtml.js")
        _ = script.setAttribute("async", "")
        _ = script.setAttribute("crossorigin", "anonymous")
        var head = dom.head
        _ = head.appendChild(script)
    }

    /// Typesets the freshly-built DOM once MathJax (loaded async) is ready.
    /// Guarded end to end: if MathJax never arrives, the TeX stays literal
    /// rather than crashing the page. (Lifted from the pre-facade Example3.)
    @MainActor
    private static func typeset() async {
        let global = JSObject.global

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
                _ = global.console.warn("Physica: MathJax unavailable — formulas left as TeX.")
                return
            }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }

        guard let mj = mathJax else { return }
        if let startup = mj.startup.promise.object {
            _ = try? await JSPromise(unsafelyWrapping: startup).value()
        }
        if mj.typesetPromise.function != nil {
            let result = mj.typesetPromise!()
            if let promise = result.object {
                _ = try? await JSPromise(unsafelyWrapping: promise).value()
            }
        }
    }
}

#endif
