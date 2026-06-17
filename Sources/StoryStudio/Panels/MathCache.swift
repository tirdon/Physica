// MathCache — memoized TeX → MathJax SVG resolution (WASI only).
//
// `MathJaxLoader.svg(for:)` is synchronous once `load()` has resolved, but a
// `tex2svg` call per recompile per formula would be wasteful — so we cache the
// SVG markup per tex. The editor resolves all of a document's math here, off the
// hot rebuild path, and hands the map to the platform-neutral compiler.

#if os(WASI)
import Physica

@MainActor
enum MathCache {
    private static var cache: [String: String] = [:]

    /// MathJax SVG for `tex`, memoized. `nil` when MathJax is unavailable or the
    /// tex fails to render — the caller then skips that element.
    static func svg(for tex: String) -> String? {
        if let cached = cache[tex] { return cached }
        guard let svg = try? MathJaxLoader.svg(for: tex) else { return nil }
        cache[tex] = svg
        return svg
    }
}
#endif
