// Host tests for the native font path: the dictionary-backed `Font` init
// (Typesetting) and the CoreText baker (PhysicaApp). Tolerance-based — `Real`
// is `Double` on the host.

import Testing
import PhysicaFoundation
import PhysicaTypesetting
@testable import PhysicaApp

private func approx(_ a: Real, _ b: Real, _ tolerance: Real = 1e-6) -> Bool {
    Swift.abs(a - b) <= tolerance
}

@Suite
struct FontDictionaryInitTests {
    @Test func lookupsHitMissesDegradeMetricsSane() {
        let square = Path.rect(width: 0.5, height: 0.7, center: SIMD2(0.25, 0.35))
        let glyphs: [Unicode.Scalar: Font.Glyph] = [
            "A": Font.Glyph(index: 5, advance: 0.6, path: square),
            "B": Font.Glyph(index: 6, advance: 0.5, path: square),
            " ": Font.Glyph(index: 3, advance: 0.3, path: Path()),
        ]
        let font = Font(glyphs: glyphs, unitsPerEm: 1000, ascender: 0.8, descender: -0.2)

        // Hits by scalar.
        #expect(font.glyphIndex(for: "A") == 5)
        #expect(approx(font.glyph(for: "A")?.advance ?? -1, 0.6))
        #expect(font.glyph(for: "A")?.path.isEmpty == false)
        #expect(approx(font.glyph(for: " ")?.advance ?? -1, 0.3))

        // Misses degrade (nil), never trap.
        #expect(font.glyph(for: "Z") == nil)
        #expect(font.glyphIndex(for: "Z") == nil)

        // Hit / miss by glyph id.
        #expect((try? font.glyph(at: 5))?.index == 5)
        #expect((try? font.glyph(at: 999)) == nil)

        // Metrics sane; count reflects the baked glyphs.
        #expect(font.glyphCount == 3)
        #expect(font.ascender > 0)
        #expect(font.descender < 0)
        #expect(approx(font.unitsPerEm, 1000))
    }

    @Test func emptyFaceStillMisses() {
        // The additive init must not disturb `Font.empty` semantics.
        #expect(Font.empty.glyph(for: "A") == nil)
        #expect(Font.empty.glyphCount == 0)
    }
}

#if os(macOS)
@Suite @MainActor
struct CoreTextFontTests {
    @Test func bakesSystemFontWithUsableGlyphsAndMetrics() {
        let font = CoreTextFont.bake(CoreTextFont.systemFont())

        // Metrics in em units, descender below the baseline.
        #expect(font.ascender > 0)
        #expect(font.descender < 0)
        #expect(font.ascender < 4)          // sanity: em-normalized, not point-scaled
        #expect(font.glyphCount > 40)       // ASCII + Latin-1 + Greek were baked

        // 'A' has a real outline and a positive advance.
        let a = font.glyph(for: "A")
        #expect(a != nil)
        #expect(a?.path.isEmpty == false)
        #expect((a?.advance ?? 0) > 0)

        // Space carries an advance even though it has no outline.
        #expect((font.glyph(for: " ")?.advance ?? 0) > 0)

        // A baked font drives TextEntity layout: "Hi" → positioned glyphs.
        let text = TextEntity("Hi", font: font, fontSize: 1).shown()
        #expect(text.textComponent.glyphs.count >= 2)
        #expect(text.localBounds.isEmpty == false)
    }

    @Test func installedDefaultsFillFontBook() {
        FontBook.reset()
        PhysicaApplication.installDefaultFonts()
        #expect(FontBook.fallback != nil)
        #expect(FontBook.hasRegistration(for: .math))
        #expect(FontBook.hasRegistration(for: .mono))
        // Body resolves through the fallback face and lays out real glyphs.
        let body = FontBook.resolve(.body).font
        #expect(body?.glyph(for: "g")?.path.isEmpty == false)
        FontBook.reset()
    }
}
#endif
