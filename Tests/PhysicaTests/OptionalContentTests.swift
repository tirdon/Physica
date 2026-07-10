import Testing
@testable import PhysicaFoundation
@testable import PhysicaAlgebra
@testable import PhysicaTypesetting
@testable import PhysicaKernel
@testable import PhysicaCharts
@testable import PhysicaPhysics
@testable import PhysicaEquationGame

/// The optional-tolerant scripted API: nil content flows through `play`/`add`/
/// `interact`/`clip.add` and the static factories without `if let` guards —
/// nil items drop out, and all-nil calls enqueue nothing (no clip, no time).
@Suite @MainActor
struct OptionalContentTests {
    @Test func allNilPlayEnqueuesNothing() {
        let scene = Scene()
        let missing: TextEntity? = nil

        let clipsBefore = scene.timeline.clips.count
        let result = scene.play(.write(missing), for: 2.5.s)

        #expect(result == nil)
        #expect(scene.timeline.clips.count == clipsBefore)
        #expect(approx(scene.timeline.duration, 0))
    }

    @Test func mixedPlayDropsNilItems() {
        let scene = Scene()
        let circle = Circle()
        scene.add(circle)
        let missing: TextEntity? = nil

        let before = scene.timeline.duration
        let result = scene.play(circle.fade(to: 0), .write(missing), for: 1.s)

        #expect(result != nil)
        #expect(approx(scene.timeline.duration, before + 1))

        scene.update(deltaTime: 2)  // past the clip: the fade really ran
        #expect(approx(circle.components[RenderStyleComponent.self]?.opacity ?? -1, 0))
    }

    @Test func optionalFactoriesReturnNilForNil() {
        #expect(Animation.write(nil as TextEntity?) == nil)
        #expect(Animation.erase(nil as TextEntity?) == nil)
        #expect(Animation.draw(nil as PathEntity?) == nil)
        #expect(Animation.erase(nil as PathEntity?) == nil)
        #expect(Animation.highlight(nil) == nil)
        #expect(Animation.shake(nil) == nil)
    }

    @Test func optionalFactoriesForwardPresentContent() {
        let maybe: TextEntity? = TextEntity(glyphs: [])
        let animation = Animation.write(maybe)
        #expect(animation?.pairs.count == 1)
        #expect(animation?.pairs.first?.blueprint.introducesTarget == true)
    }

    @Test func optionalAddSkipsNilAndInsertsPresent() {
        let scene = Scene()
        let circle = Circle()
        let missing: Circle? = nil

        let clipsBefore = scene.timeline.clips.count
        #expect(scene.add(missing) == nil)
        #expect(scene.timeline.clips.count == clipsBefore)

        #expect(scene.add(circle, missing) != nil)
        scene.update(deltaTime: 0.016)  // the 0-duration add clip applies on advance
        #expect(scene.contains(circle))
    }

    @Test func allNilInteractRunsNothing() {
        let scene = Scene()
        let handle = scene.interact(.shake(nil), for: 0.4.s)
        #expect(handle == nil)
    }

    @Test func composerAddSkipsNil() {
        let scene = Scene()
        let circle = Circle()
        scene.add(circle)
        let missing: TextEntity? = nil

        scene.play { clip in
            clip.add(.write(missing), for: 2.s)
            clip.add(circle.fade(to: 0.5), for: 1.s)
        }
        #expect(approx(scene.timeline.duration, 1))
    }

    @Test func textEntityAcceptsNilFont() {
        let explicit = TextEntity("Hi", font: nil)
        let defaulted = TextEntity("Hi")
        #expect(explicit.glyphCount == defaulted.glyphCount)
    }
}
