import Testing
@testable import PhysicaMath
@testable import PhysicaAlgebra
@testable import PhysicaGeometry
@testable import PhysicaTypesetting
@testable import PhysicaKernel
@testable import PhysicaPlotting
@testable import PhysicaStory
@testable import PhysicaPhysics
@testable import PhysicaEquationGame

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

    @Test func chainedDescriptorsAccumulate() {
        let entity = Entity()
        let chained = entity.opacity(0.8).shift(-1.j)  // both blueprints carried
        #expect(chained.pairs.count == 2)
        #expect(chained.animationTargets.count == 1)
        #expect(chained.debugString.contains("fade(to: 0.80)"))
        #expect(chained.debugString.contains("shift"))
    }

    @Test func addConsumedBlueprintsDoNotReplay() {
        let scene = Scene()
        let bob = Circle().move(to: 2.i)   // spec handle pattern
        scene.add(bob)
        scene.play(bob.move(to: 1.j), for: 1.s)

        // The chained handle carries the original move, but add() consumed it:
        // the play clip must contain only the new move track.
        #expect(scene.timeline.clips[1].tracks.count == 1)
        scene.update(deltaTime: 0.001)  // add clip applies the carried move instantly
        let circle = bob.animationTargets[0]
        #expect(approx(circle.position, Position(2, 0, 0), tolerance: 1e-2))
        scene.update(deltaTime: 2.0)
        #expect(approx(circle.position, Position(0, 1, 0), tolerance: 1e-3))
    }

    @Test func unlabeledDurationBuilder() {
        let scene = Scene()
        let circle = Entity()
        let star = Entity()
        scene.add(circle, star)
        scene.play(3.s) {
            circle.move(to: .center)
            star.opacity(0.8).shift(-1.j)
        }
        let clip = scene.timeline.clips[1]
        #expect(approx(clip.duration, 3))
        #expect(clip.tracks.count == 3)  // move + fade + shift
    }

    @Test func clipComposerBundlesOneClip() {
        let scene = Scene()
        let a = Entity()
        let b = Entity()
        scene.add(a, b)
        scene.play { clip in
            clip.add(a.move(to: 1.i), for: 1.s)
            clip.add(b.shift(-1.j), for: 2.s, offset: 0.5.s)
        }
        #expect(scene.timeline.clips.count == 2)
        let clip = scene.timeline.clips[1]
        #expect(clip.tracks.count == 2)
        #expect(approx(clip.duration, 2.5))  // max(offset + duration)

        scene.update(deltaTime: 3.0)
        #expect(approx(a.position, Position(1, 0, 0), tolerance: 1e-3))
        #expect(approx(b.position, Position(0, -1, 0), tolerance: 1e-3))
    }

    @Test func drawAutoAddsItsEntity() {
        let scene = Scene()
        let shape = Circle()
        scene.wait(1.s)
        scene.play(.draw(shape), for: 1.s)
        #expect(scene.entities.isEmpty)  // nothing until the clip is reached

        scene.update(deltaTime: 1.5)  // into the draw clip
        #expect(scene.entities.contains { $0 === shape })

        scene.seek(to: 0.5)  // scrub before the draw clip — auto-add rewinds too
        #expect(!scene.entities.contains { $0 === shape })

        scene.seek(to: 2.0)
        #expect(scene.entities.contains { $0 === shape })
    }

    @Test func explicitAddKeepsOwnershipOverAutoAdd() {
        let scene = Scene()
        let shape = Circle()
        scene.add(shape)
        scene.wait(1.s)
        scene.play(.draw(shape), for: 1.s)

        scene.update(deltaTime: 2.5)
        scene.seek(to: 0.5)  // rewinds only the draw clip — the add clip still owns the entity
        #expect(scene.entities.contains { $0 === shape })
    }

    @Test func eraseRemovesEntityAtClipEnd() {
        let scene = Scene()
        let shape = Circle()
        scene.play(.draw(shape), for: 1.s)
        scene.wait(1.s)
        scene.play(.erase(shape), for: 1.s, easing: .linear)

        scene.update(deltaTime: 2.5)  // mid-erase: still present, stroke retracting
        #expect(scene.entities.contains { $0 === shape })
        let mid = shape.components[PathComponent.self]!
        #expect(approx(mid.strokeProgress, 0.5 / 0.85, tolerance: 1e-2))
        #expect(mid.fillOpacityFactor == 0)

        scene.update(deltaTime: 1.0)  // past the end: gone, fully retracted
        #expect(!scene.entities.contains { $0 === shape })
        #expect(approx(shape.components[PathComponent.self]!.strokeProgress, 0))

        scene.seek(to: 1.5)  // scrub back before the erase: restored, fully drawn
        #expect(scene.entities.contains { $0 === shape })
        #expect(approx(shape.components[PathComponent.self]!.strokeProgress, 1))
        #expect(approx(shape.components[PathComponent.self]!.fillOpacityFactor, 1))
    }

    @Test func erasePreservesPainterOrderOnRewind() {
        let scene = Scene()
        let a = Circle()
        let b = Rectangle()
        scene.add(a, b)
        scene.play(.erase(a), for: 1.s)

        scene.update(deltaTime: 1.5)
        #expect(scene.entities.count == 1)

        scene.seek(to: 0.2)  // re-inserted at its old index, not appended
        #expect(scene.entities.count == 2)
        #expect(scene.entities.first === a)
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

    @Test func separateUnitMovesPinEachEntityIndividually() {
        let scene = Scene()
        let a = Circle(radius: 0.5)
        a.position = Position(0, 2, 0)
        let b = Circle(radius: 0.5)
        b.position = Position(2, 0, 0)
        scene.add(a, b)
        scene.play(a.move(to: .bottom), b.move(to: .bottom), for: 1.s)
        scene.update(deltaTime: 1.2)

        // No implicit grouping: each entity's own bounds land on the edge.
        let frame = scene.frameBounds
        #expect(approx(a.position.y, frame.min.y + 1, tolerance: 1e-3))
        #expect(approx(b.position.y, frame.min.y + 1, tolerance: 1e-3))
        #expect(approx(a.position.x, 0))
        #expect(approx(b.position.x, 2))
    }

    @Test func groupMovePreservesRelativeLayout() {
        let scene = Scene()
        let a = Circle(radius: 0.5)
        a.position = Position(0, 2, 0)
        let b = Circle(radius: 0.5)
        scene.add(a, b)
        scene.play(Group(a, b).move(to: .bottom), for: 1.s)
        scene.update(deltaTime: 1.2)

        // One rigid unit: the union's bottom sits at the edge + padding and
        // the members keep their relative offset (string length survives).
        #expect(approx(a.position.y - b.position.y, 2))
        #expect(approx(a.position.x, 0))
        let frame = scene.frameBounds
        #expect(approx(b.position.y - 0.5, frame.min.y + 0.5, tolerance: 1e-3))

        // The transient bag never wiped the members' scene membership.
        #expect(a.scene === scene)
        #expect(b.scene === scene)

        // Scrubbing back restores both starts.
        scene.seek(to: 0)
        #expect(approx(a.position.y, 2))
        #expect(approx(b.position.y, 0))
    }

    @Test func groupBagAcceptsStoredAnimationHandles() {
        let scene = Scene()
        let circle = Circle(radius: 0.5)
        let handle = circle.move(to: Position(0, 1, 0))  // spec-style stored handle
        scene.add(handle)
        let group = Group(handle)
        #expect(group.children.count == 1)
        #expect(group.children[0] === circle)
    }

    @Test func saveAndRestoreStateRoundTrip() {
        let scene = Scene()
        let a = Circle(radius: 0.5)
        a.position = Position(0, 1, 0)
        let b = Circle(radius: 0.5)
        b.position = Position(1, 0, 0)
        scene.add(a, b)
        let bag = Group(a, b)

        scene.wait(0.5.s)
        scene.play(bag.saveState())                       // 0-duration capture at 0.5
        scene.play(a.shift(2.i), b.shift(-1.j), for: 1.s) // scatter [0.5, 1.5]
        scene.wait(0.5.s)
        scene.play(bag.restoreState(), for: 1.s)          // [2.0, 3.0]

        scene.update(deltaTime: 1.0)                      // mid-scatter
        #expect(approx(a.position.x, 1, tolerance: 0.4))
        scene.update(deltaTime: 0.7)                      // scattered, mid-wait
        #expect(approx(a.position.x, 2))
        #expect(approx(b.position.y, -1))

        scene.update(deltaTime: 1.5)                      // restore done
        #expect(approx(a.position.x, 0))
        #expect(approx(a.position.y, 1))
        #expect(approx(b.position.x, 1))
        #expect(approx(b.position.y, 0))

        // Scrubbing into the scatter window shows the scattered state again;
        // scrubbing before the save removes the capture component.
        scene.seek(to: 1.5)
        #expect(approx(a.position.x, 2))
        scene.seek(to: 0)
        #expect(a.components[SavedStateComponent.self] == nil)
    }

    @Test func restoreWithoutSaveIsANoOp() {
        let scene = Scene()
        let circle = Circle(radius: 0.5)
        circle.position = Position(1, 1, 0)
        scene.add(circle)
        scene.play(circle.restoreState(), for: 1.s)
        scene.update(deltaTime: 1.2)
        #expect(approx(circle.position.x, 1))
        #expect(approx(circle.position.y, 1))
    }
}
