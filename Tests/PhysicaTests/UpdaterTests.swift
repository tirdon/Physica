import Testing
@testable import Physica

/// Stand-in for Line until shapes land: an entity with a bindable endpoint.
@MainActor
private final class Segment: Entity {
    var end: Position = .zero
}

@Suite @MainActor
struct UpdaterTests {
    @Test func closureUpdaterRunsEachFrame() {
        let scene = Scene()
        let follower = Segment()
        let leader = Entity()
        leader.position = Position(2, 0, 0)
        scene.insert(follower)
        scene.insert(leader)

        follower.updater = { $0.end = leader.position }
        #expect(follower.end == .zero)

        scene.update(deltaTime: 0.016)
        #expect(follower.end == Position(2, 0, 0))

        leader.position = Position(0, 5, 0)
        scene.update(deltaTime: 0.016)
        #expect(follower.end == Position(0, 5, 0))
    }

    @Test func settingNilRemovesUpdaters() {
        let scene = Scene()
        let follower = Segment()
        scene.insert(follower)
        follower.updater = { $0.end = 1.i }
        follower.updater = nil
        scene.update(deltaTime: 0.016)
        #expect(follower.end == .zero)
        #expect(!follower.components.has(UpdaterComponent.self))
    }

    @Test func settingReplacesPreviousUpdater() {
        let scene = Scene()
        let follower = Segment()
        scene.insert(follower)
        follower.updater = { $0.end = 1.i }
        follower.updater = { $0.end = 2.j }
        scene.update(deltaTime: 0.016)
        #expect(follower.end == Position(0, 2, 0))
        #expect(follower.components[UpdaterComponent.self]?.entries.count == 1)
    }

    @Test func keyPathBindSyncsValues() {
        let scene = Scene()
        let follower = Segment()
        let leader = Entity()
        scene.insert(follower)
        scene.insert(leader)

        follower.bind(\.end, to: leader, \.position)
        leader.position = Position(4, -1, 0)
        scene.update(deltaTime: 0.016)
        #expect(follower.end == Position(4, -1, 0))
    }

    @Test func addAndRemoveSpecificUpdater() {
        let scene = Scene()
        let follower = Segment()
        scene.insert(follower)

        let first = follower.addUpdater { $0.end.x += 1 }
        follower.addUpdater { $0.end.y += 1 }
        scene.update(deltaTime: 0.016)
        #expect(follower.end == Position(1, 1, 0))

        follower.removeUpdater(id: first)
        scene.update(deltaTime: 0.016)
        #expect(follower.end == Position(1, 2, 0))
    }

    @Test func updatersRunAfterSystems() {
        // The updater must see positions already advanced by systems this frame.
        let scene = Scene()
        let leader = Entity()
        leader.components[StepComponent.self] = StepComponent()
        let follower = Segment()
        scene.insert(leader)
        scene.insert(follower)
        scene.registerSystem(StepSystem.self)
        follower.updater = { $0.end = leader.position }

        scene.update(deltaTime: 0.016)
        #expect(follower.end == leader.position)
        #expect(leader.position.x == 1)
    }
}

private struct StepComponent: Component {}

@MainActor
private struct StepSystem: System {
    init(scene: Scene) {}
    func update(context: SceneUpdateContext) {
        for entity in context.entities(matching: .has(StepComponent.self)) {
            entity.position.x += 1
        }
    }
}
