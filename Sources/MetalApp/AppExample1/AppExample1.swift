// AppExample1 — the native Document example, the counterpart of AppExample0's
// window. It authors an article on the `Document` DSL (the native sibling of the
// wasm Example3) and presents it — no wasm, no browser bundle. `run()` opens the
// article in an in-app WebView window; `write(to:)` renders the same
// self-contained HTML to a file. Both typeset math via a CDN MathJax loader.
//
// The article carries a live `presentation {}` deck: `run()` floats a real Metal
// view over its slot (step it with the ‹ / › buttons), and `write(to:)` bakes the
// deck to a short H.264 movie embedded as a `<video>` in the file.

#if os(macOS)
import PhysicaApp
import Foundation

@main
struct AppExample1 {
    @MainActor
    static func main() throws {
        HamiltonianArticle.document.run()

        // Render the same article to a single self-contained HTML file instead
        // (the deck becomes an embedded <video>; tune its size/fps if you like):
        //   try HamiltonianArticle.document.write(to: URL(fileURLWithPath: "article.html"))
    }
}

#else

@main
struct AppExample1 {
    static func main() {
        print("AppExample1 presents a Document — build and run it on macOS:")
        print("  swift run AppExample1   # opens the article in a window")
    }
}

#endif


