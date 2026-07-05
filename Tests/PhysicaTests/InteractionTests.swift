import Testing
@testable import PhysicaFoundation
@testable import PhysicaAlgebra
@testable import PhysicaTypesetting
@testable import PhysicaKernel
@testable import PhysicaCharts
@testable import PhysicaPhysics
@testable import PhysicaEquationGame

@Suite @MainActor struct InteractionTests {
    private let tolerance: Real = 1e-4

    @Test func interactRunsWhileTimelinePaused() {
        let scene = Scene()
        let dot = Circle(radius: 0.2)
        scene.add(dot)
        scene.seek(to: 0) // pauses the timeline
        #expect(scene.timeline.isPaused)

        scene.interact(dot.move(to: Position(3, 0, 0)), for: 1.s)
        scene.update(deltaTime: 0.5)
        #expect(dot.position.x > 0)
        let timelineTime = scene.timeline.currentTime
        scene.update(deltaTime: 0.6)
        #expect(abs(dot.position.x - 3) < tolerance)
        // The paused timeline never moved.
        #expect(scene.timeline.currentTime == timelineTime)
    }

    @Test func interactRunsInParallelWithTimeline() {
        let scene = Scene()
        let a = Circle(radius: 0.2)
        let b = Circle(radius: 0.2)
        scene.add(a, b)
        scene.play(a.move(to: Position(2, 0, 0)), for: 1.s)
        scene.interact(b.move(to: Position(0, 2, 0)), for: 1.s)
        scene.update(deltaTime: 0.5)
        #expect(a.position.x > 0)
        #expect(b.position.y > 0)
        scene.update(deltaTime: 0.6)
        #expect(abs(a.position.x - 2) < tolerance)
        #expect(abs(b.position.y - 2) < tolerance)
        #expect(scene.interactions.isIdle)
    }

    @Test func interactDrawIntroducesEntityImmediately() {
        let scene = Scene()
        let shape = Circle(radius: 0.5)
        #expect(shape.scene == nil)
        scene.interact(.draw(shape), for: 0.5.s)
        // AddEntitiesTrack applied at begin — visible this frame.
        #expect(scene.entities.contains(where: { $0 === shape }))
        scene.update(deltaTime: 0.6)
        #expect(scene.interactions.isIdle)
    }

    @Test func interactEraseRemovesEntityAtEnd() {
        let scene = Scene()
        let shape = Circle(radius: 0.5)
        scene.add(shape)
        scene.seek(to: 0) // flush the 0-duration add clip
        scene.interact(.erase(shape), for: 0.5.s)
        #expect(scene.entities.contains(where: { $0 === shape }))
        scene.update(deltaTime: 0.6)
        #expect(!scene.entities.contains(where: { $0 === shape }))
    }

    @Test func completePolicyJumpsToEndState() {
        let scene = Scene()
        let dot = Circle(radius: 0.2)
        scene.add(dot)
        let handle = scene.interact(dot.move(to: Position(4, 0, 0)), for: 1.s, onInterrupt: .complete)
        scene.update(deltaTime: 0.3)
        scene.interactions.interrupt(handle, in: scene)
        #expect(abs(dot.position.x - 4) < tolerance)
        #expect(scene.interactions.isIdle)
    }

    @Test func cancelPolicyRewindsToStart() {
        let scene = Scene()
        let dot = Circle(radius: 0.2)
        dot.position = Position(1, 1, 0)
        scene.add(dot)
        scene.interact(dot.move(to: Position(4, 0, 0)), for: 1.s, onInterrupt: .cancel)
        scene.update(deltaTime: 0.3)
        scene.interactions.interruptAll(in: scene)
        #expect(abs(dot.position.x - 1) < tolerance)
        #expect(abs(dot.position.y - 1) < tolerance)
    }

    @Test func interruptAllAppliesEachPolicy() {
        let scene = Scene()
        let lands = Circle(radius: 0.2)
        let aborts = Circle(radius: 0.2)
        scene.add(lands, aborts)
        scene.interact(lands.move(to: Position(2, 0, 0)), for: 1.s, onInterrupt: .complete)
        scene.interact(aborts.move(to: Position(0, 2, 0)), for: 1.s, onInterrupt: .cancel)
        scene.update(deltaTime: 0.4)
        scene.interactions.interruptAll(in: scene)
        #expect(abs(lands.position.x - 2) < tolerance)
        #expect(abs(aborts.position.y) < tolerance)
        #expect(scene.interactions.isIdle)
    }

    @Test func mainTimelineSeekDoesNotDisturbInteractionClips() {
        let scene = Scene()
        let dot = Circle(radius: 0.2)
        scene.add(dot)
        scene.play(dot.color(.red), for: 1.s)
        scene.interact(dot.move(to: Position(3, 0, 0)), for: 1.s)
        scene.update(deltaTime: 0.5)
        let midway = dot.position.x
        #expect(midway > 0)
        scene.seek(to: 0)
        // Seek replayed the timeline but left the interaction's spatial state.
        #expect(abs(dot.position.x - midway) < tolerance)
        scene.update(deltaTime: 0.6)
        #expect(abs(dot.position.x - 3) < tolerance)
    }

    @Test func interactionAddedEntityPersistsAcrossSeekToZero() {
        let scene = Scene()
        scene.wait(0.5.s) // some scrubbable history
        let shape = Circle(radius: 0.4)
        scene.interact(.draw(shape), for: 0.3.s)
        scene.update(deltaTime: 0.4)
        scene.seek(to: 0)
        // Same policy as physics state: not part of the scrub history.
        #expect(scene.entities.contains(where: { $0 === shape }))
    }

    @Test func consumedPairIDsSharedWithPlay() {
        let scene = Scene()
        let bob = Circle(radius: 0.2).move(to: Position(2, 0, 0))
        scene.add(bob) // consumes the carried move
        scene.seek(to: 0) // flush the add clip — the move applies here
        #expect(abs(bob.position.x - 2) < tolerance)
        // The stored handle interacts later: only the new shift applies.
        scene.interact(bob.shift(Position(1, 0, 0)), for: 0.5.s)
        scene.update(deltaTime: 0.6)
        #expect(abs(bob.position.x - 3) < tolerance)
    }

    @Test func zeroDurationInteractCompletesImmediately() {
        let scene = Scene()
        let dot = Circle(radius: 0.2)
        scene.add(dot)
        var fired = false
        scene.interact(dot.move(to: Position(5, 0, 0)), for: 0.s, completion: { fired = true })
        #expect(abs(dot.position.x - 5) < tolerance)
        #expect(fired)
        #expect(scene.interactions.isIdle)
    }

    @Test func completionFiresOnNaturalFinish() {
        let scene = Scene()
        let dot = Circle(radius: 0.2)
        scene.add(dot)
        var fired = false
        scene.interact(dot.move(to: Position(1, 0, 0)), for: 0.4.s, completion: { fired = true })
        scene.update(deltaTime: 0.2)
        #expect(!fired)
        scene.update(deltaTime: 0.3)
        #expect(fired)
    }

    @Test func debugStringListsActiveClips() {
        let scene = Scene()
        let dot = Circle(radius: 0.2)
        scene.add(dot)
        #expect(scene.interactions.debugString == "interactions idle")
        scene.interact(dot.move(to: Position(1, 0, 0)), for: 1.s)
        #expect(scene.interactions.debugString.contains("move"))
    }

    // MARK: Owner-tagged reveals — interact(owner:) / interrupt(ownedBy:)

    @Test func interactOwnerRegistersReveal() {
        let scene = Scene()
        let owner = Circle(radius: 0.3)
        scene.add(owner)
        let cx = Circle(radius: 0.2)
        let cy = Circle(radius: 0.2)
        #expect(!scene.hasInteraction(ownedBy: owner))
        scene.interact(.draw(cx), .draw(cy), for: 0.6.s, owner: owner)
        #expect(scene.hasInteraction(ownedBy: owner))
        #expect(scene.entities.contains(where: { $0 === cx }))
        #expect(scene.entities.contains(where: { $0 === cy }))
    }

    @Test func interruptOwnedByRemovesAfterDrawCompletes() {
        let scene = Scene()
        let owner = Circle(radius: 0.3)
        scene.add(owner)
        let cx = Circle(radius: 0.2)
        let cy = Circle(radius: 0.2)
        scene.interact(.draw(cx), .draw(cy), for: 0.5.s, owner: owner)
        scene.update(deltaTime: 0.6) // draw finishes; arrows persist past the clip
        #expect(scene.interactions.isIdle)
        #expect(scene.entities.contains(where: { $0 === cx }))
        #expect(scene.hasInteraction(ownedBy: owner))
        scene.interrupt(ownedBy: owner)
        #expect(!scene.entities.contains(where: { $0 === cx }))
        #expect(!scene.entities.contains(where: { $0 === cy }))
        #expect(!scene.hasInteraction(ownedBy: owner))
    }

    @Test func interruptOwnedByRemovesMidDrawAndStopsReinsert() {
        let scene = Scene()
        let owner = Circle(radius: 0.3)
        scene.add(owner)
        let cx = Circle(radius: 0.2)
        scene.interact(.draw(cx), for: 0.6.s, owner: owner)
        scene.update(deltaTime: 0.2) // mid-flight
        #expect(scene.entities.contains(where: { $0 === cx }))
        scene.interrupt(ownedBy: owner)
        #expect(!scene.entities.contains(where: { $0 === cx }))
        #expect(scene.interactions.isIdle)
        // The dropped draw must not re-insert cx on the next advance.
        scene.update(deltaTime: 0.3)
        #expect(!scene.entities.contains(where: { $0 === cx }))
    }

    @Test func interruptAllClearsOwnerRevealsButLandsOthers() {
        let scene = Scene()
        let owner = Circle(radius: 0.3)
        let plain = Circle(radius: 0.2)
        scene.add(owner, plain)
        scene.seek(to: 0)
        let reveal = Circle(radius: 0.2)
        scene.interact(.draw(reveal), for: 0.5.s, owner: owner)
        scene.update(deltaTime: 0.6) // reveal completes and persists
        scene.interact(plain.move(to: Position(2, 0, 0)), for: 1.s) // non-owner, mid-flight
        scene.update(deltaTime: 0.2)
        scene.interactions.interruptAll(in: scene)
        // The owner reveal is cleared even though it had finished drawing...
        #expect(!scene.entities.contains(where: { $0 === reveal }))
        #expect(!scene.hasInteraction(ownedBy: owner))
        // ...while the non-owner clip landed (default .complete) and its target stays.
        #expect(abs(plain.position.x - 2) < tolerance)
        #expect(scene.entities.contains(where: { $0 === plain }))
        #expect(scene.interactions.isIdle)
    }
}
