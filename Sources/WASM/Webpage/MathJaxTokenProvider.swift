// MathJaxTokenProvider — the web TokenGlyphProvider: one MathJax SVG per token,
// rendered synchronously (MathJaxLoader.load() resolved at boot) and cached by
// TeX. measuredGlyphs keeps the glyphs baseline-relative so a row's tokens share
// a baseline. A token that fails to render (or yields no glyphs, e.g. a space)
// degrades to an empty run with a measured width, so layout still spaces it.

import PhysicaFoundation
import PhysicaAlgebra
import PhysicaTypesetting
import PhysicaKernel
import PhysicaCharts
import PhysicaPhysics
import PhysicaEquationGame

#if os(WASI)
import JavaScriptKit

@MainActor
public final class MathJaxTokenProvider: TokenGlyphProvider {
    private var cache: [String: TokenGlyphRun] = [:]
    /// Em width charged to a token that produced no glyphs (operators MathJax
    /// renders thinly, or a stray space), so gaps still read.
    private let emptyWidth: Real

    public init(emptyWidth: Real = 0.4) {
        self.emptyWidth = emptyWidth
    }

    public func glyphs(for token: DisplayToken) -> TokenGlyphRun {
        if let cached = cache[token.tex] { return cached }
        let run = render(token.tex)
        cache[token.tex] = run
        return run
    }

    private func render(_ tex: String) -> TokenGlyphRun {
        guard let markup = try? MathJaxLoader.svg(for: tex),
              let measured = try? MathSVG.measuredGlyphs(fromSVG: markup),
              !measured.glyphs.isEmpty
        else {
            return TokenGlyphRun(glyphs: [], width: emptyWidth)
        }
        var bounds = Bounds.empty
        for glyph in measured.glyphs {
            bounds = bounds.union(LiteralEntity.glyphBounds([glyph], fontSize: 1))
        }
        let width = bounds.isEmpty ? emptyWidth : bounds.max.x
        return TokenGlyphRun(glyphs: measured.glyphs, width: width)
    }
}
#endif
