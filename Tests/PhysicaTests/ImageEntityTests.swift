// Image entity — the bitmap box: snapshot emission (`ImagePrimitive.url`),
// transform/opacity riding the ordinary animation machinery, bounds for
// move(to: Unit)/highlight, and the empty-source degrade. Render-agnostic like
// everything in the core: assertions are all against `scene.snapshot()`.

import Testing
@testable import PhysicaFoundation
@testable import PhysicaAlgebra
@testable import PhysicaTypesetting
@testable import PhysicaKernel
@testable import PhysicaCharts
@testable import PhysicaPhysics
@testable import PhysicaEquationGame

@Suite @MainActor struct ImageEntityTests {
    private let tolerance: Real = 1e-4

    private func imagePrimitives(in scene: Scene) -> [ImagePrimitive] {
        scene.snapshot().primitives.compactMap {
            if case .image(let image) = $0 { return image }
            return nil
        }
    }

    @Test func snapshotCarriesTheBitmapBox() {
        let scene = Scene()
        let cat = Image("cat.png", width: 3)
        cat.position = Position(1, 2, 0)
        scene.add(cat)
        scene.update(deltaTime: 0.001)   // apply the 0-duration add clip

        let images = imagePrimitives(in: scene)
        #expect(images.count == 1)
        guard let primitive = images.first else { return }
        #expect(primitive.url == "cat.png")
        #expect(primitive.text.isEmpty)
        #expect(primitive.center.distance(to: Position(1, 2, 0)) < tolerance)
        #expect(abs(primitive.size.x - 3) < tolerance)
        #expect(abs(primitive.size.y - 3) < tolerance)   // square box by default
        #expect(abs(primitive.opacity - 1) < tolerance)
    }

    @Test func heightOverridesTheSquareBox() {
        let banner = Image("banner.png", width: 4, height: 1)
        #expect(abs(banner.size.y - 1) < tolerance)
        #expect(banner.localBounds.size.x - 4 < tolerance)
        #expect(abs(banner.localBounds.size.y - 1) < tolerance)
    }

    @Test func emptySourceEmitsNothing() {
        let scene = Scene()
        scene.add(Image(""))
        scene.update(deltaTime: 0.001)
        #expect(imagePrimitives(in: scene).isEmpty)
    }

    @Test func scaleAndFadeRideTheTimeline() {
        let scene = Scene()
        let logo = Image("logo.png", width: 2)
        scene.add(logo)
        scene.play(logo.scale(by: 2), logo.fade(to: 0.25), for: 1.s)

        scene.seek(to: 1)
        var images = imagePrimitives(in: scene)
        #expect(images.count == 1)
        #expect(abs((images.first?.size.x ?? 0) - 4) < 1e-3)      // 2 × scale 2
        #expect(abs((images.first?.opacity ?? 0) - 0.25) < 1e-3)

        scene.seek(to: 0)   // scrub-safe: back to the blueprint values
        images = imagePrimitives(in: scene)
        #expect(abs((images.first?.size.x ?? 0) - 2) < 1e-3)
        #expect(abs((images.first?.opacity ?? 0) - 1) < 1e-3)
    }

    @Test func rotationRidesTheSnapshot() {
        let scene = Scene()
        let photo = Image("photo.png", width: 2)
        scene.add(photo)
        scene.play(photo.rotate(by: Real.pi / 4), for: 1.s)

        scene.seek(to: 1)
        var images = imagePrimitives(in: scene)
        #expect(abs((images.first?.rotation ?? 0) - Real.pi / 4) < 1e-3)
        #expect(abs((images.first?.size.x ?? 0) - 2) < 1e-3)   // pure roll: scale untouched

        scene.seek(to: 0)   // scrub-safe: roll rewinds with the transform
        images = imagePrimitives(in: scene)
        #expect(abs(images.first?.rotation ?? 1) < 1e-3)
    }

    @Test func emojiBoxesCarryTheEntityRoll() {
        let scene = Scene()
        let party = TextEntity("🎉").shown()
        scene.add(party)
        scene.play(party.rotate(by: Real.pi / 6), for: 1.s)

        scene.seek(to: 1)
        let images = imagePrimitives(in: scene)
        #expect(!images.isEmpty)
        #expect(images.allSatisfy { abs($0.rotation - Real.pi / 6) < 1e-3 && $0.url == nil })
    }

    @Test func imagesAreTappableAndDraggable() {
        // Hit-testing runs on worldBounds, which `localBounds` supplies — so
        // the ordinary interaction components work on a bitmap unchanged.
        let scene = Scene()
        var tapped = false
        var dragBegan = false
        let card = Image("card.png", width: 2)
        card.position = Position(2, 0, 0)
        card.components[DraggableComponent.self] = DraggableComponent(
            payload: .tag("card"),
            onTap: { _ in tapped = true },
            onDragBegan: { _ in dragBegan = true })
        scene.add(card)
        scene.seek(to: 0)

        // Press + release inside the 2×2 box, within the slop → tap.
        scene.dispatch(.pointerDown(Position(2.6, 0.6, 0)))
        scene.dispatch(.pointerUp(Position(2.6, 0.6, 0)))
        #expect(tapped)
        #expect(!dragBegan)

        // Past the slop → drag, and the box follows the pointer.
        scene.dispatch(.pointerDown(Position(2, 0, 0)))
        scene.dispatch(.pointerMoved(Position(3, 1, 0)))
        #expect(dragBegan)
        #expect(abs(card.position.x - 3) < tolerance)
        #expect(abs(card.position.y - 1) < tolerance)
        scene.dispatch(.pointerUp(Position(3, 1, 0)))
    }

    @Test func emojiGlyphsKeepANilURL() {
        let scene = Scene()
        // Font.default is empty — emoji lay out anyway; .shown() reveals
        // without a write (text writeProgress starts at 0 by design).
        let text = TextEntity("🎉").shown()
        scene.add(text)
        scene.update(deltaTime: 0.001)
        let images = imagePrimitives(in: scene)
        #expect(!images.isEmpty)
        #expect(images.allSatisfy { $0.url == nil && !$0.text.isEmpty })
    }
}
