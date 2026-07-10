// CoreTextFont — bakes a Physica `Font` from a `CTFont`, the native counterpart
// of the wasm `FontLoader` (which fetches a TTF and runs the pure-Swift glyf
// parser). Modern macOS system faces are CFF/TTC — unsupported by the glyf
// parser — so instead of feeding their bytes to `Font(data:)`, we walk each
// glyph's `CGPath` (`CTFontCreatePathForGlyph`) into a Physica `Path` and hand
// the pre-baked glyphs to `Font(glyphs:unitsPerEm:ascender:descender:)`.
//
// Coordinates: the CTFont is created at `designSize` points, so
// `CTFontCreatePathForGlyph`/`CTFontGetAdvancesForGlyphs`/`CTFontGetAscent`
// return values scaled to that point size; dividing by `designSize` reaches em
// units (1 em = 1.0), matching the glyf parser's y-up em outlines exactly.

import PhysicaFoundation
import PhysicaTypesetting

#if os(macOS)
import CoreText
import CoreGraphics

enum CoreTextFont {
    /// Point size the CTFont is instantiated at; coordinates divide by it to
    /// reach em units. A moderate size (not 1.0) keeps San Francisco on a
    /// normal-text optical variant.
    static let designSize: CGFloat = 64

    /// Bakes `ctFont` (already created at `designSize`) into a Physica `Font`
    /// over `charset()` — printable ASCII, Latin-1, Greek, and common
    /// punctuation/math. Glyphs the face lacks are simply omitted (misses
    /// degrade in layout, exactly like the TTF path).
    static func bake(_ ctFont: CTFont) -> Font {
        let scale = Real(1) / Real(designSize)
        let ascender = Real(CTFontGetAscent(ctFont)) * scale
        // CTFontGetDescent returns a positive distance below the baseline; the
        // Font contract stores the descender negative.
        let descender = -Real(CTFontGetDescent(ctFont)) * scale
        let unitsPerEm = Real(CTFontGetUnitsPerEm(ctFont))

        var glyphs: [Unicode.Scalar: Font.Glyph] = [:]
        for scalar in charset() {
            if let glyph = glyph(for: scalar, in: ctFont, scale: scale) {
                glyphs[scalar] = glyph
            }
        }
        return Font(
            glyphs: glyphs, unitsPerEm: unitsPerEm,
            ascender: ascender, descender: descender
        )
    }

    /// Named system faces created at `designSize`, ready for `bake`.
    static func systemFont() -> CTFont {
        CTFontCreateUIFontForLanguage(.system, designSize, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, designSize, nil)
    }

    /// A face by PostScript name (`"Menlo-Regular"`, `"Times-Italic"`). Returns
    /// nil when CoreText substitutes a different face for an unknown name, so
    /// the facade can fall back to the system font deliberately.
    static func namedFont(_ name: String) -> CTFont? {
        let font = CTFontCreateWithName(name as CFString, designSize, nil)
        let resolved = CTFontCopyPostScriptName(font) as String
        return resolved.caseInsensitiveCompare(name) == .orderedSame ? font : nil
    }

    // MARK: One glyph

    private static func glyph(
        for scalar: Unicode.Scalar, in ctFont: CTFont, scale: Real
    ) -> Font.Glyph? {
        var utf16 = Array(String(scalar).utf16)
        var cgGlyphs = [CGGlyph](repeating: 0, count: utf16.count)
        let mapped = CTFontGetGlyphsForCharacters(ctFont, &utf16, &cgGlyphs, utf16.count)
        guard mapped, let cgGlyph = cgGlyphs.first, cgGlyph != 0 else { return nil }

        var ids = [cgGlyph]
        var sizes = [CGSize(width: 0, height: 0)]
        CTFontGetAdvancesForGlyphs(ctFont, .horizontal, &ids, &sizes, 1)
        let advance = Real(sizes[0].width) * scale

        // Space (and other blank glyphs) return no path but a real advance —
        // keep them so `font.glyph(for: " ")?.advance` measures true spacing.
        let path = CTFontCreatePathForGlyph(ctFont, cgGlyph, nil).map {
            convert($0, scale: scale)
        } ?? Path()
        return Font.Glyph(index: Int(cgGlyph), advance: advance, path: path)
    }

    /// Walks a glyph `CGPath` (y-up, points at `designSize`) into a Physica
    /// `Path` in em units. Physica `Path` supports move/line/quad/cubic, which
    /// is exactly the CGPath element set.
    private static func convert(_ cgPath: CGPath, scale: Real) -> Path {
        var contours: [Path.Contour] = []
        var start = SIMD2<Real>(0, 0)
        var segments: [Path.Segment] = []
        var open = false
        var closed = false

        func point(_ p: CGPoint) -> SIMD2<Real> {
            SIMD2(Real(p.x) * scale, Real(p.y) * scale)
        }
        func flush() {
            if open, !segments.isEmpty {
                contours.append(Path.Contour(start: start, segments: segments, isClosed: closed))
            }
            segments = []
            open = false
            closed = false
        }

        cgPath.applyWithBlock { elementPointer in
            let element = elementPointer.pointee
            let points = element.points
            switch element.type {
            case .moveToPoint:
                flush()
                start = point(points[0])
                open = true
            case .addLineToPoint:
                segments.append(.line(to: point(points[0])))
            case .addQuadCurveToPoint:
                segments.append(.quadCurve(control: point(points[0]), to: point(points[1])))
            case .addCurveToPoint:
                segments.append(.curve(
                    control1: point(points[0]), control2: point(points[1]), to: point(points[2])
                ))
            case .closeSubpath:
                closed = true
            @unknown default:
                break
            }
        }
        flush()
        return Path(contours: contours)
    }

    // MARK: Charset

    /// The scalars to bake: printable ASCII, Latin-1 supplement, Greek, and the
    /// punctuation/math the brief calls out (dashes, curly quotes, ellipsis, °
    /// · × ÷ ± √ π ℓ θ ∞ ≈ ≠ ≤ ≥ → −).
    static func charset() -> [Unicode.Scalar] {
        var values: [UInt32] = []
        values.append(contentsOf: 0x20...0x7E)     // printable ASCII
        values.append(contentsOf: 0xA0...0xFF)     // Latin-1 supplement
        values.append(contentsOf: 0x370...0x3FF)   // Greek and Coptic
        values.append(contentsOf: [
            0x2013, 0x2014,                         // – —
            0x2018, 0x2019, 0x201C, 0x201D,         // ‘ ’ “ ”
            0x2026,                                 // …
            0x00B0, 0x00B7, 0x00D7, 0x00F7, 0x00B1, // ° · × ÷ ±
            0x221A, 0x03C0, 0x2113, 0x03B8,         // √ π ℓ θ
            0x221E, 0x2248, 0x2260, 0x2264, 0x2265, // ∞ ≈ ≠ ≤ ≥
            0x2192, 0x2212,                         // → −
        ])
        return values.compactMap { Unicode.Scalar($0) }
    }
}
#endif
