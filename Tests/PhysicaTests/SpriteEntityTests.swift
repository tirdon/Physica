// Sprite entity — the in-canvas bitmap quad: snapshot emission
// (`SpritePrimitive`, distinct from the DOM layer's `ImagePrimitive`),
// transform/opacity riding the ordinary animation machinery, bounds for
// move(to: Unit)/hit-testing, and the empty-source degrade. The textured-quad
// drawing itself is renderer-side (wasm; verified in headless Chrome) — the
// host locks the value seam, like everything in the core.

import Testing
@testable import PhysicaFoundation
@testable import PhysicaAlgebra
@testable import PhysicaTypesetting
@testable import PhysicaKernel
@testable import PhysicaCharts
@testable import PhysicaPhysics
@testable import PhysicaEquationGame

@Suite @MainActor struct SpriteEntityTests {
    private let tolerance: Real = 1e-4

    private func spritePrimitives(in scene: Scene) -> [SpritePrimitive] {
        scene.snapshot().primitives.compactMap {
            if case .sprite(let sprite) = $0 { return sprite }
            return nil
        }
    }

    @Test func snapshotCarriesTheTextureQuad() {
        let scene = Scene()
        let cat = Sprite("cat.png", width: 3)
        cat.position = Position(1, 2, 0)
        scene.add(cat)
        scene.update(deltaTime: 0.001)   // apply the 0-duration add clip

        let sprites = spritePrimitives(in: scene)
        #expect(sprites.count == 1)
        guard let primitive = sprites.first else { return }
        #expect(primitive.url == "cat.png")
        #expect(primitive.center.distance(to: Position(1, 2, 0)) < tolerance)
        #expect(abs(primitive.size.x - 3) < tolerance)
        #expect(abs(primitive.size.y - 3) < tolerance)   // square box by default
        #expect(abs(primitive.rotation) < tolerance)
        #expect(abs(primitive.opacity - 1) < tolerance)

        // In-canvas, not the DOM layer: no ImagePrimitive is emitted for it.
        let images = scene.snapshot().primitives.filter {
            if case .image = $0 { return true }
            return false
        }
        #expect(images.isEmpty)
    }

    @Test func heightOverridesTheSquareBox() {
        let banner = Sprite("banner.png", width: 4, height: 1)
        #expect(abs(banner.size.y - 1) < tolerance)
        #expect(abs(banner.localBounds.size.x - 4) < tolerance)
        #expect(abs(banner.localBounds.size.y - 1) < tolerance)
    }

    @Test func emptySourceEmitsNothing() {
        let scene = Scene()
        scene.add(Sprite(""))
        scene.update(deltaTime: 0.001)
        #expect(spritePrimitives(in: scene).isEmpty)
    }

    @Test func animationsRideTheTimeline() {
        let scene = Scene()
        let logo = Sprite("logo.png", width: 2)
        scene.add(logo)
        scene.play(
            logo.scale(by: 2), logo.fade(to: 0.25), logo.rotate(by: Real.pi / 4), for: 1.s
        )

        scene.seek(to: 1)
        var sprites = spritePrimitives(in: scene)
        #expect(sprites.count == 1)
        #expect(abs((sprites.first?.size.x ?? 0) - 4) < 1e-3)          // 2 × scale 2
        #expect(abs((sprites.first?.opacity ?? 0) - 0.25) < 1e-3)
        #expect(abs((sprites.first?.rotation ?? 0) - Real.pi / 4) < 1e-3)

        scene.seek(to: 0)   // scrub-safe: back to the blueprint values
        sprites = spritePrimitives(in: scene)
        #expect(abs((sprites.first?.size.x ?? 0) - 2) < 1e-3)
        #expect(abs((sprites.first?.opacity ?? 0) - 1) < 1e-3)
        #expect(abs(sprites.first?.rotation ?? 1) < 1e-3)
    }

    @Test func spritesHitTestLikeAnyEntity() {
        // worldBounds comes from localBounds, so taps land with no new code.
        let scene = Scene()
        var tapped = false
        let card = Sprite("card.png", width: 2)
        card.position = Position(2, 0, 0)
        card.components[TapComponent.self] = TapComponent { _ in tapped = true }
        scene.add(card)
        scene.seek(to: 0)

        scene.dispatch(.pointerDown(Position(2.6, 0.6, 0)))   // inside the 2×2 box
        scene.dispatch(.pointerUp(Position(2.6, 0.6, 0)))
        #expect(tapped)
    }
}
