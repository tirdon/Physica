import Testing
@testable import Physica

@Suite @MainActor
struct AnimationTests {
    @Test func factoriesAreDeferredDescriptors() {
        let entity = Entity()
        let animation = entity.move(to: Position(3, 0, 0))
        #expect(entity.position == .zero)  // no immediate mutation
        #expect(animation.pairs.count == 1)
        #expect(animation.duration == nil)
        #expect(animation.offset == .zero)
        #expect(animation.animationTargets.first === entity)
    }

    @Test func animationForwardsTransformToPrimaryTarget() {
        let entity = Entity()
        entity.position = Position(1, 1, 0)
        let handle = entity.move(to: 2.i)  // spec: `let bob = Circle().move(to: ...)`
        #expect(handle.position == Position(1, 1, 0))
        handle.position = Position(5, 0, 0)
        #expect(entity.position == Position(5, 0, 0))
    }

    @Test func freshDescriptorsDoNotAccumulate() {
        let entity = Entity()
        let first = entity.move(to: 1.i)
        let second = first.move(to: 2.j)  // new descriptor, same target
        #expect(second.pairs.count == 1)
        #expect(second.animationTargets.first === entity)
        #expect(second.debugString.contains("move(to: (0.000, 2.000, 0.000))"))
    }

    @Test func wrapperInitSetsTiming() {
        let entity = Entity()
        let wrapped = Animation(entity.shift(-1.i), for: 2.s, offset: 1.s)
        #expect(wrapped.duration == 2.s)
        #expect(wrapped.offset == 1.s)
        #expect(wrapped.pairs.count == 1)
    }

    @Test func builderComposesAnimations() {
        let scene = Scene()
        let a = Entity()
        let b = Entity()
        scene.add(a, b)
        scene.play(for: 2.s) {
            a.move(to: 1.i)
            b.fade(to: 0)
        }
        #expect(scene.timeline.clips.count == 2)
        #expect(approx(scene.timeline.clips[1].duration, 2))
        #expect(scene.timeline.clips[1].tracks.count == 2)
    }

    @Test func debugLabels() {
        let entity = Entity()
        entity.name = "bob"
        let animation = entity.move(to: Position(1, 1, 0))
        #expect(animation.debugString == "Animation[bob.move(to: (1.000, 1.000, 0.000))]")
    }
}
