// TokenGlyphProvider — turns one equation token into renderable glyphs.
//
// Each token renders to its OWN glyph run (the Equalynx pattern), so the source
// of those glyphs is pluggable: a TrueType Font for host tests and simple text,
// MathJax for the web (M9), or unit squares for layout tests. The protocol is
// SYNCHRONOUS (decision D5): MathJax's tex2svg is sync once its startup promise
// resolved, so the only await in the whole pipeline is one loader call at boot.

/// Baseline-relative glyphs for one token, in em units (y = 0 at the text
/// baseline, pen starting at x = 0), plus the advance width.
import PhysicaMath
import PhysicaAlgebra
import PhysicaGeometry
import PhysicaTypesetting
import PhysicaKernel

public struct TokenGlyphRun: Sendable {
    public var glyphs: [TextComponent.PositionedGlyph]
    public var width: Real

    public init(glyphs: [TextComponent.PositionedGlyph], width: Real) {
        self.glyphs = glyphs
        self.width = width
    }
}

@MainActor
public protocol TokenGlyphProvider: AnyObject {
    func glyphs(for token: DisplayToken) -> TokenGlyphRun
}

/// Styling for an equation's rows.
public struct EquationStyle: Sendable {
    public var fontSize: Real
    public var color: Color
    /// Faded opacity applied to a row once a later row supersedes it.
    public var inactiveRowOpacity: Real
    /// Gaps (em) between adjacent tokens, by relationship.
    public var interGap: Real
    public var opGap: Real
    public var equalsGap: Real
    /// Vertical spacing between stacked equation rows (world units).
    public var rowSpacing: Real

    public init(
        fontSize: Real = 1,
        color: Color = .white,
        inactiveRowOpacity: Real = 0.45,
        interGap: Real = 0.12,
        opGap: Real = 0.18,
        equalsGap: Real = 0.28,
        rowSpacing: Real = 0.4
    ) {
        self.fontSize = fontSize
        self.color = color
        self.inactiveRowOpacity = inactiveRowOpacity
        self.interGap = interGap
        self.opGap = opGap
        self.equalsGap = equalsGap
        self.rowSpacing = rowSpacing
    }
}

/// Attached to each token's TextEntity so the game can read which move address a
/// dragged token carries.
public struct TokenComponent: Component {
    public var token: DisplayToken
    public init(token: DisplayToken) { self.token = token }
    public var debugString: String { "token(\(token.value))" }
}

// MARK: - Font provider (host / simple text)

/// Renders a token's human-facing `value` with a TrueType Font. Glyphs come out
/// baseline-relative (Font outlines already have their origin on the baseline).
@MainActor
public final class FontTokenGlyphProvider: TokenGlyphProvider {
    private let font: Font
    private let spaceAdvance: Real

    public init(font: Font) {
        self.font = font
        self.spaceAdvance = font.glyph(for: " ")?.advance ?? 0.3
    }

    public func glyphs(for token: DisplayToken) -> TokenGlyphRun {
        var glyphs: [TextComponent.PositionedGlyph] = []
        var pen: Real = 0
        for scalar in token.value.unicodeScalars {
            if scalar == " " {
                pen += spaceAdvance
                continue
            }
            guard let glyph = font.glyph(for: scalar) else {
                pen += 0.5
                continue
            }
            if !glyph.path.isEmpty {
                glyphs.append(TextComponent.PositionedGlyph(path: glyph.path, offset: SIMD2(pen, 0)))
            }
            pen += glyph.advance
        }
        return TokenGlyphRun(glyphs: glyphs, width: pen)
    }
}

// MARK: - Stub provider (layout tests)

/// Deterministic geometry with no font file: each token is one solid box,
/// width = `value` length × `unitWidth`, height `unitHeight`, baseline at y = 0.
/// Operators/`=` keep a minimum width so gaps are visible in tests.
@MainActor
public final class StubTokenGlyphProvider: TokenGlyphProvider {
    public var unitWidth: Real
    public var unitHeight: Real

    public init(unitWidth: Real = 0.5, unitHeight: Real = 0.7) {
        self.unitWidth = unitWidth
        self.unitHeight = unitHeight
    }

    public func glyphs(for token: DisplayToken) -> TokenGlyphRun {
        let count = Swift.max(token.value.count, 1)
        let width = Real(count) * unitWidth
        // A box from x∈[0,width], y∈[0,unitHeight] — baseline at the bottom.
        let box = Path.rect(
            width: width, height: unitHeight,
            center: SIMD2(width / 2, unitHeight / 2)
        )
        return TokenGlyphRun(
            glyphs: [TextComponent.PositionedGlyph(path: box, offset: .zero)],
            width: width
        )
    }
}
