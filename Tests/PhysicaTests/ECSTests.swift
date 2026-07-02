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

private struct CounterComponent: Component {
    var ticks: Int = 0
    var debugString: String { "ticks(\(ticks))" }
}

@MainActor
private struct CountingSystem: System {
    init(scene: Scene) {}

    func update(context: SceneUpdateContext) {
        for entity in context.entities(matching: .has(CounterComponent.self)) {
            var counter = entity.components[CounterComponent.self]!
            counter.ticks += 1
            entity.components[CounterComponent.self] = counter
        }
    }
}

@Suite @MainActor
struct ECSTests {
    @Test func componentSetBasics() {
        var set = ComponentSet()
        #expect(set.count == 0)
        #expect(!set.has(CounterComponent.self))

        set[CounterComponent.self] = CounterComponent(ticks: 3)
        #expect(set.has(CounterComponent.self))
        #expect(set[CounterComponent.self]?.ticks == 3)

        set.set(TransformComponent())
        #expect(set.count == 2)
        #expect(set.debugString == "[Counter, Transform]")

        set.remove(CounterComponent.self)
        #expect(!set.has(CounterComponent.self))
        #expect(set.count == 1)
    }

    @Test func entityIdentityAndHashing() {
        let a = Entity()
        let b = Entity()
        #expect(a.id != b.id)
        #expect(a == a)
        #expect(a != b)
        let set: Set<Entity> = [a, b, a]
        #expect(set.count == 2)
    }

    @Test func transformSugar() {
        let entity = Entity()
        entity.position = Position(1, 2, 3)
        #expect(entity.position == Position(1, 2, 3))
        #expect(entity.components.has(TransformComponent.self))

        entity.scale = SIMD3(2, 2, 2)
        entity.orientation = Quaternion(angle: .pi / 2, axis: 1.k)
        #expect(approx(entity.transform.scale.x, 2))
        // position survives independent field writes
        #expect(entity.position == Position(1, 2, 3))
    }

    @Test func groupHierarchyAndWorldTransform() {
        let child = Entity()
        child.position = 1.i
        let group = Group(child)
        group.position = 2.j

        #expect(child.parent === group)
        #expect(approx(child.worldTransform.position, Position(1, 2, 0)))

        group.orientation = Quaternion(angle: .pi / 2, axis: 1.k)
        #expect(approx(child.worldTransform.position, Position(0, 3, 0)))

        group.removeChild(child)
        #expect(child.parent == nil)
        #expect(group.children.isEmpty)
    }

    @Test func groupBounds() {
        let a = Entity()
        a.position = Position(-1, 0, 0)
        let b = Entity()
        b.position = Position(3, 2, 0)
        let group = Group(a, b)
        let bounds = group.localBounds
        #expect(approx(bounds.min, Position(-1, 0, 0)))
        #expect(approx(bounds.max, Position(3, 2, 0)))
        #expect(approx(group.center, Position(1, 1, 0)))
    }

    @Test func sceneQueryReachesNestedEntities() {
        let scene = Scene()
        let inner = Entity()
        inner.components[CounterComponent.self] = CounterComponent()
        let group = Group(inner)
        scene.insert(group)
        scene.insert(Entity())

        let matches = scene.performQuery(.has(CounterComponent.self))
        #expect(matches.count == 1)
        #expect(matches.first === inner)
        #expect(scene.performQuery(.all).count == 3)
        #expect(inner.scene === scene)
    }

    @Test func systemRegistrationAndUpdate() {
        let scene = Scene()
        let entity = Entity()
        entity.components[CounterComponent.self] = CounterComponent()
        scene.insert(entity)

        scene.registerSystem(CountingSystem.self)
        scene.registerSystem(CountingSystem.self)  // dedup

        scene.update(deltaTime: 1.0 / 60.0)
        scene.update(deltaTime: 1.0 / 60.0)
        #expect(entity.components[CounterComponent.self]?.ticks == 2)
    }

    @Test func systemSuspension() {
        let scene = Scene()
        let entity = Entity()
        entity.components[CounterComponent.self] = CounterComponent()
        scene.insert(entity)
        scene.registerSystem(CountingSystem.self)

        scene.systems.setSuspended(true, typeID: ObjectIdentifier(CountingSystem.self))
        scene.update(deltaTime: 0.016)
        #expect(entity.components[CounterComponent.self]?.ticks == 0)

        scene.systems.setSuspended(false, typeID: ObjectIdentifier(CountingSystem.self))
        scene.update(deltaTime: 0.016)
        #expect(entity.components[CounterComponent.self]?.ticks == 1)
    }

    @Test func entityDebugString() {
        let entity = Entity()
        entity.name = "bob"
        entity.position = Position(1, 0, 0)
        #expect(entity.debugString == "Entity 'bob' pos(1.000, 0.000, 0.000) [Transform]")
    }
}
