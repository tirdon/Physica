import Testing
@testable import PhysicaFoundation
@testable import PhysicaAlgebra
@testable import PhysicaTypesetting
@testable import PhysicaKernel
@testable import PhysicaCharts
@testable import PhysicaPhysics
@testable import PhysicaEquationGame

@MainActor
private func makeText(glyphs count: Int) -> TextEntity {
    let square = Path.rect(width: 0.5, height: 0.7, center: SIMD2(0.25, 0.35))
    return TextEntity(glyphs: (0..<count).map {
        TextComponent.PositionedGlyph(path: square, offset: SIMD2(Real($0) * 0.7, 0))
    }).shown()
}

@Suite @MainActor
struct GlyphSliceTests {
    @Test func sliceColorAnimatesAndRewindsToInherit() {
        let scene = Scene()
        let text = makeText(glyphs: 3)
        scene.add(text)
        scene.play(text[0..<2].color(.red), for: 1.s, easing: .linear)

        scene.update(deltaTime: 0.5)
        let mid = text.textComponent.glyphs
        let expected = Color.lerp(.white, .red, 0.5)  // base style color is white
        #expect(approx(Real(mid[0].color?.g ?? -1), Real(expected.g), tolerance: 1e-3))
        #expect(mid[2].color == nil)  // outside the slice

        scene.update(deltaTime: 1.0)
        #expect(text.textComponent.glyphs[0].color == .red)
        #expect(text.textComponent.glyphs[1].color == .red)

        scene.seek(to: 0)
        #expect(text.textComponent.glyphs[0].color == nil)  // override fully removed
    }

    @Test func sliceFadeFlowsIntoSnapshotAlpha() {
        let scene = Scene()
        let text = makeText(glyphs: 2)
        scene.add(text)
        scene.play(text[1].fade(to: 0), for: 1.s, easing: .linear)

        scene.update(deltaTime: 1.5)
        #expect(approx(text.textComponent.glyphs[1].opacity, 0))
        let primitives = scene.snapshot().primitives
        guard case .path(let kept) = primitives[0], case .path(let faded) = primitives[1] else {
            Issue.record("expected path primitives")
            return
        }
        #expect(approx(Real(kept.style.fill?.a ?? 0), 1))
        #expect(approx(Real(faded.style.fill?.a ?? 1), 0))

        scene.seek(to: 0)
        #expect(approx(text.textComponent.glyphs[1].opacity, 1))
    }

    @Test func gradientMixSpansTheSlice() {
        let scene = Scene()
        let text = makeText(glyphs: 3)
        scene.add(text)
        scene.play(text.color(mix: [.red, .blue]), for: 1.s, easing: .linear)

        scene.update(deltaTime: 1.5)
        let glyphs = text.textComponent.glyphs
        #expect(glyphs[0].color == .red)     // first stop
        #expect(glyphs[2].color == .blue)    // last stop
        let mid = Color.lerp(.red, .blue, 0.5)
        #expect(approx(Real(glyphs[1].color?.r ?? -1), Real(mid.r), tolerance: 1e-3))
        #expect(approx(Real(glyphs[1].color?.b ?? -1), Real(mid.b), tolerance: 1e-3))
    }

    @Test func outOfRangeSlicesAreSafeNoOps() {
        let scene = Scene()
        let text = makeText(glyphs: 2)
        scene.add(text)
        scene.play(text[5..<9].color(.red), text[1...].fade(to: 0.5), for: 0.5.s)
        scene.update(deltaTime: 1.0)
        #expect(text.textComponent.glyphs[0].color == nil)
        #expect(text.textComponent.glyphs[1].color == nil)
        #expect(approx(text.textComponent.glyphs[0].opacity, 1))
        #expect(approx(text.textComponent.glyphs[1].opacity, 0.5))  // 1... clamps to glyph 1
    }
}
