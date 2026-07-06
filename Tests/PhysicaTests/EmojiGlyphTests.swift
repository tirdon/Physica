// Emoji image-glyph tests — cluster classification, layout emitting image
// glyphs for emoji, and the write path fading images in (snapshot-level
// ImagePrimitive opacity) instead of stroke-then-fill.

import Testing
@testable import PhysicaFoundation
@testable import PhysicaAlgebra
@testable import PhysicaTypesetting
@testable import PhysicaKernel
@testable import PhysicaCharts
@testable import PhysicaPhysics
@testable import PhysicaEquationGame

@MainActor
private func makeMixedText(writeProgress: Real) -> TextEntity {
    let square = Path.rect(width: 0.5, height: 0.7, center: SIMD2(0.25, 0.35))
    let text = TextEntity(glyphs: [
        TextComponent.PositionedGlyph(path: square, offset: SIMD2(-0.6, 0)),
        TextComponent.PositionedGlyph(
            path: Path(), offset: SIMD2(0.1, 0), image: GlyphImage(text: "🎉")
        ),
    ])
    var component = text.textComponent
    component.writeProgress = writeProgress
    text.textComponent = component
    return text
}

@Suite @MainActor struct EmojiGlyphTests {
    @Test func classifiesEmojiClusters() {
        #expect(TextEntity.isEmojiCluster("🎉"))
        #expect(TextEntity.isEmojiCluster("☕"))            // default emoji presentation
        #expect(TextEntity.isEmojiCluster("👨‍👩‍👧"))            // ZWJ family sequence
        #expect(TextEntity.isEmojiCluster("1️⃣"))            // keycap via VS16
        #expect(!TextEntity.isEmojiCluster("A"))
        #expect(!TextEntity.isEmojiCluster("1"))            // bare digit stays text
        #expect(!TextEntity.isEmojiCluster("→"))
    }

    @Test func snapshotEmitsImagePrimitiveForShownEmoji() {
        let scene = Scene()
        let text = makeMixedText(writeProgress: 1)
        scene.add(text)
        scene.update(deltaTime: 0.001)   // apply the 0-duration add clip

        let primitives = scene.snapshot().primitives
        let images = primitives.compactMap { primitive -> ImagePrimitive? in
            if case .image(let image) = primitive { return image }
            return nil
        }
        let paths = primitives.filter { if case .path = $0 { return true } else { return false } }
        #expect(images.count == 1)
        #expect(paths.count == 1)                            // the vector glyph
        #expect(images.first?.text == "🎉")
        #expect(abs((images.first?.opacity ?? 0) - 1) < 1e-3)
        #expect((images.first?.size.x ?? 0) > 0 && (images.first?.size.y ?? 0) > 0)
    }

    @Test func emojiFadesInDuringWriteInsteadOfStrokeFill() {
        let scene = Scene()
        // Glyph 1 (the emoji) mid-window: its fade should be partial.
        let text = makeMixedText(writeProgress: 0.75)
        scene.add(text)
        scene.update(deltaTime: 0.001)

        let images = scene.snapshot().primitives.compactMap { primitive -> ImagePrimitive? in
            if case .image(let image) = primitive { return image }
            return nil
        }
        #expect(images.count == 1)
        #expect((images.first?.opacity ?? 0) > 0.05 && (images.first?.opacity ?? 1) < 0.999)
    }

    @Test func hiddenEmojiEmitsNothing() {
        let scene = Scene()
        let text = makeMixedText(writeProgress: 0)
        scene.add(text)
        scene.update(deltaTime: 0.001)

        let images = scene.snapshot().primitives.compactMap { primitive -> ImagePrimitive? in
            if case .image(let image) = primitive { return image }
            return nil
        }
        #expect(images.isEmpty)
    }
}
