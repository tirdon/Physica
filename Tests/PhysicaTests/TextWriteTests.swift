import Testing
@testable import Physica

@MainActor
private func makeTwoGlyphText() -> TextEntity {
    let square = Path.rect(width: 0.5, height: 0.7, center: SIMD2(0.25, 0.35))
    return TextEntity(glyphs: [
        TextComponent.PositionedGlyph(path: square, offset: SIMD2(-0.6, 0)),
        TextComponent.PositionedGlyph(path: square, offset: SIMD2(0.1, 0)),
    ])
}

@Suite @MainActor
struct TextWriteTests {
    @Test func glyphFactorEndpoints() {
        for index in 0..<3 {
            let hidden = TextComponent.glyphFactors(writeProgress: 0, index: index, count: 3, lagRatio: 0.5)
            #expect(hidden.stroke == 0 && hidden.fill == 0)
            let done = TextComponent.glyphFactors(writeProgress: 1, index: index, count: 3, lagRatio: 0.5)
            #expect(approx(done.stroke, 1) && approx(done.fill, 1))
        }
    }

    @Test func staggerOrdersGlyphs() {
        // Mid-write: earlier glyphs are strictly ahead.
        let first = TextComponent.glyphFactors(writeProgress: 0.5, index: 0, count: 4, lagRatio: 0.5)
        let last = TextComponent.glyphFactors(writeProgress: 0.5, index: 3, count: 4, lagRatio: 0.5)
        #expect(first.stroke > last.stroke)

        // Stroke completes before fill starts within one glyph.
        let window = 1 / (1 + 0.5 * 3.0)  // d for count=4, lag=0.5
        let strokeDoneAt = 0.85 * window
        let factors = TextComponent.glyphFactors(
            writeProgress: Real(strokeDoneAt), index: 0, count: 4, lagRatio: 0.5
        )
        #expect(approx(factors.stroke, 1, tolerance: 1e-3))
        #expect(factors.fill < 0.05)
    }

    @Test func writeAnimationDrivesProgress() {
        let scene = Scene()
        let text = makeTwoGlyphText()
        scene.add(text)
        scene.play(text.write(), for: 2.s)

        scene.update(deltaTime: 0.001)
        #expect(approx(text.textComponent.writeProgress, 0, tolerance: 1e-2))

        scene.update(deltaTime: 1.0)
        let mid = text.textComponent.writeProgress
        #expect(mid > 0.3 && mid < 0.7)

        scene.update(deltaTime: 1.5)
        #expect(approx(text.textComponent.writeProgress, 1))
    }

    @Test func snapshotEmitsPerGlyphPrimitivesWithReveal() {
        let scene = Scene()
        let text = makeTwoGlyphText()
        scene.add(text)
        scene.play(text.write(), for: 2.s, easing: .linear)
        scene.update(deltaTime: 1.2)  // 60%: glyph 0 finishing, glyph 1 mid-stroke

        let primitives = scene.snapshot().primitives
        #expect(primitives.count == 2)
        guard case .path(let g0) = primitives[0], case .path(let g1) = primitives[1] else {
            Issue.record("expected path primitives")
            return
        }
        #expect(g0.strokeProgress > g1.strokeProgress)
        #expect(g0.style.stroke != nil)

        // Hidden text emits nothing.
        scene.seek(to: 0)
        #expect(scene.snapshot().primitives.isEmpty)
    }

    @Test func shownSkipsTheReveal() {
        let scene = Scene()
        let text = makeTwoGlyphText().shown()
        scene.add(text)
        scene.update(deltaTime: 0.016)
        let primitives = scene.snapshot().primitives
        #expect(primitives.count == 2)
        guard case .path(let g0) = primitives[0] else {
            Issue.record("expected path primitive")
            return
        }
        #expect(approx(g0.strokeProgress, 1))
        #expect(approx(g0.fillOpacityFactor, 1))
    }

    @Test func boundsCoverLayout() {
        let text = makeTwoGlyphText()
        let bounds = text.localBounds
        #expect(approx(bounds.min.x, -0.6, tolerance: 1e-3))
        #expect(approx(bounds.max.x, 0.6 + 0.1 - 0.1, tolerance: 1e-2))
    }
}
