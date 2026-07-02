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

private struct TickComponent: Component {
    var ticks: Int = 0
}

@MainActor
private struct TickSystem: System {
    init(scene: Scene) {}
    func update(context: SceneUpdateContext) {
        for entity in context.entities(matching: .has(TickComponent.self)) {
            var tick = entity.components[TickComponent.self]!
            tick.ticks += 1
            entity.components[TickComponent.self] = tick
        }
    }
}

@Suite @MainActor
struct TimelineTests {
    @Test func addIsAZeroDurationClipAppliedOnFirstAdvance() {
        let scene = Scene()
        let entity = Entity()
        scene.add(entity)

        #expect(scene.timeline.clips.count == 1)
        #expect(scene.timeline.duration == 0)
        #expect(scene.entities.isEmpty)  // not yet — membership rides the timeline

        scene.update(deltaTime: 0.016)
        #expect(scene.entities.count == 1)
        #expect(entity.scene === scene)
    }

    @Test func carriedBlueprintsApplyInstantlyOnAdd() {
        let scene = Scene()
        let entity = Entity()
        scene.add(entity.move(to: Position(2, -1, 0)))  // `Circle().move(to:)` pattern
        scene.update(deltaTime: 0.016)
        #expect(approx(entity.position, Position(2, -1, 0)))
    }

    @Test func sequentialPlayback() {
        let scene = Scene()
        let entity = Entity()
        scene.add(entity)
        scene.play(entity.move(to: 4.i), for: 2.s, easing: .linear)
        scene.wait()

        #expect(approx(scene.timeline.duration, 3))

        scene.update(deltaTime: 1.0)
        #expect(approx(entity.position.x, 2))
        scene.update(deltaTime: 1.0)
        #expect(approx(entity.position.x, 4))
        #expect(!scene.timeline.isFinished)
        scene.update(deltaTime: 1.0)
        #expect(scene.timeline.isFinished)
        #expect(approx(scene.timeline.currentTime, 3))
    }

    @Test func durationDefaultsAndOverrides() {
        let scene = Scene()
        let entity = Entity()
        scene.add(entity)
        scene.play(entity.move(to: 1.i))            // default 1 s
        scene.play(entity.move(to: 2.i), for: 5.s)  // explicit
        #expect(approx(scene.timeline.clips[1].duration, 1))
        #expect(approx(scene.timeline.clips[2].duration, 5))
    }

    @Test func groupOffsetsAndDurations() {
        let scene = Scene()
        let triangle = Entity()
        let square = Entity()
        scene.add(triangle, square)

        let a1 = Animation(triangle.shift(-1.i), for: 2.s, offset: 1.s, easing: .linear)
        scene.play(group: a1, Animation(square.shift(1.i), for: 3.s, easing: .linear))

        let clip = scene.timeline.clips[1]
        #expect(approx(clip.duration, 3))

        scene.update(deltaTime: 0.5)  // t = 0.5: triangle still waiting on its offset
        #expect(approx(triangle.position.x, 0))
        #expect(approx(square.position.x, 0.5 / 3))

        scene.update(deltaTime: 1.5)  // t = 2.0: triangle halfway through its 2 s
        #expect(approx(triangle.position.x, -0.5))

        scene.update(deltaTime: 1.0)  // t = 3.0: both done
        #expect(approx(triangle.position.x, -1))
        #expect(approx(square.position.x, 1))
    }

    @Test func seekMatchesAdvance() {
        func build() -> (Scene, Entity) {
            let scene = Scene()
            let entity = Entity()
            scene.add(entity)
            scene.play(entity.move(to: Position(4, 2, 0)), for: 2.s)
            scene.play(entity.shift(-2.j))
            scene.wait()
            return (scene, entity)
        }

        let (advanced, advancedEntity) = build()
        for _ in 0..<7 { advanced.update(deltaTime: 0.37) }

        let (sought, soughtEntity) = build()
        sought.update(deltaTime: 0.001)  // arm the first clips
        sought.seek(to: 7 * 0.37)

        #expect(approx(advancedEntity.position, soughtEntity.position, tolerance: 1e-3))
    }

    @Test func scrubBeforeAddHidesEntities() {
        let scene = Scene()
        let entity = Entity()
        scene.wait()                       // [0, 1): empty scene
        scene.add(entity)                  // appears at t = 1
        scene.play(entity.move(to: 2.i), for: 1.s)

        // play through everything
        scene.update(deltaTime: 3.0)
        #expect(scene.entities.count == 1)
        #expect(approx(entity.position.x, 2))

        scene.seek(to: 0.5)                // before the add clip
        #expect(scene.entities.isEmpty)

        scene.seek(to: 1.5)                // re-applies add + half the move
        #expect(scene.entities.count == 1)
        #expect(approx(entity.position.x, 2 * Easing.smooth.apply(0.5)))

        scene.seek(to: 0)                  // all the way back
        #expect(scene.entities.isEmpty)
        #expect(approx(entity.position.x, 0))  // move rewound to its start
    }

    @Test func pauseSuspendsExactlyOneSystemForItsWindow() {
        let scene = Scene()
        let entity = Entity()
        entity.components[TickComponent.self] = TickComponent()
        scene.add(entity)
        scene.registerSystem(TickSystem.self)

        scene.wait(1.s)
        scene.pause(TickSystem.self)       // default 1 s window
        scene.wait(1.s)

        // 24 steps of 1/8 s = 3 s. The pause window [1.0, 2.0) suspends exactly 8.
        for _ in 0..<24 {
            scene.update(deltaTime: 0.125)
        }
        #expect(entity.components[TickComponent.self]?.ticks == 16)
        #expect(!scene.systems.isSuspended(typeID: ObjectIdentifier(TickSystem.self)))
    }

    @Test func seekPausesPlaybackAndResumeContinues() {
        let scene = Scene()
        let entity = Entity()
        entity.components[TickComponent.self] = TickComponent()
        scene.add(entity)
        scene.registerSystem(TickSystem.self)
        scene.play(entity.move(to: 4.i), for: 4.s, easing: .linear)

        scene.update(deltaTime: 1.0)
        #expect(approx(entity.position.x, 1))

        scene.seek(to: 2.0)
        #expect(approx(entity.position.x, 2))
        #expect(scene.timeline.isPaused)

        let ticksAfterSeek = entity.components[TickComponent.self]!.ticks
        scene.update(deltaTime: 1.0)  // paused: no timeline advance, no systems
        #expect(approx(entity.position.x, 2))
        #expect(entity.components[TickComponent.self]!.ticks == ticksAfterSeek)

        scene.resume()
        scene.update(deltaTime: 1.0)
        #expect(approx(entity.position.x, 3))
        #expect(entity.components[TickComponent.self]!.ticks == ticksAfterSeek + 1)
    }

    @Test func updatersRunAfterSeek() {
        let scene = Scene()
        let leader = Entity()
        let follower = Entity()
        scene.add(leader, follower)
        scene.play(leader.move(to: 4.i), for: 2.s, easing: .linear)
        follower.updater = { $0.position = leader.position + 1.j }

        scene.update(deltaTime: 2.0)
        #expect(approx(follower.position, Position(4, 1, 0)))

        scene.seek(to: 1.0)
        #expect(approx(follower.position, Position(2, 1, 0)))  // derived state re-ran
    }

    @Test func timelineEventStream() async {
        let scene = Scene()
        let entity = Entity()
        let stream = scene.timeline.eventStream()

        scene.add(entity)
        scene.wait(1.s)
        scene.update(deltaTime: 2.0)

        var events: [TimelineEvent] = []
        for await event in stream {
            events.append(event)
            if events.count == 5 { break }
        }
        #expect(events[0] == .clipStarted(index: 0, label: "add(Entity)"))
        #expect(events[1] == .clipFinished(index: 0))
        #expect(events[2] == .clipStarted(index: 1, label: "wait(1.00s)"))
        #expect(events[3] == .clipFinished(index: 1))
        #expect(events[4] == .finished)
    }

    @Test func timelineDebugString() {
        let scene = Scene()
        let entity = Entity()
        entity.name = "bob"
        scene.add(entity)
        scene.play(entity.move(to: 1.i), for: 2.s)
        let expected = """
        timeline 0.00/2.00s clips(2):
          @0.00s add(bob) (0.00s)
          @0.00s bob.move(to: (1.000, 0.000, 0.000)) (2.00s)
        """
        #expect(scene.timeline.debugString == expected)
    }
}
