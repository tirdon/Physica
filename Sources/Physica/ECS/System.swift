// System protocol and the ordered registry that drives per-frame updates.

import PhysicaMath
import PhysicaGeometry
import PhysicaTypesetting

@MainActor
public protocol System {
    init(scene: Scene)
    func update(context: SceneUpdateContext)
}

@MainActor
public struct SceneUpdateContext {
    public let scene: Scene
    public let deltaTime: TimeInterval
    /// Current timeline position (seconds since scene start).
    public let timelineTime: TimeInterval

    public func entities(matching query: EntityQuery) -> [Entity] {
        scene.performQuery(query)
    }
}

@MainActor
public struct EntityQuery {
    let predicate: @MainActor (Entity) -> Bool

    public init(where predicate: @escaping @MainActor (Entity) -> Bool) {
        self.predicate = predicate
    }

    public static func has<T: Component>(_ type: T.Type) -> EntityQuery {
        EntityQuery { $0.components.has(type) }
    }

    public static func has<A: Component, B: Component>(_ a: A.Type, _ b: B.Type) -> EntityQuery {
        EntityQuery { $0.components.has(a) && $0.components.has(b) }
    }

    public static var all: EntityQuery {
        EntityQuery { _ in true }
    }
}

/// Ordered system storage with per-type suspension (used by `scene.pause(System.self)`).
@MainActor
final class SystemRegistry {
    private struct Slot {
        let typeID: ObjectIdentifier
        let system: any System
        var isSuspended: Bool = false
    }

    private var slots: [Slot] = []

    /// Registers once per type, preserving registration order.
    func register<S: System>(_ type: S.Type, scene: Scene) {
        let key = ObjectIdentifier(type)
        guard !slots.contains(where: { $0.typeID == key }) else { return }
        slots.append(Slot(typeID: key, system: S(scene: scene)))
    }

    func setSuspended(_ suspended: Bool, typeID: ObjectIdentifier) {
        guard let index = slots.firstIndex(where: { $0.typeID == typeID }) else { return }
        slots[index].isSuspended = suspended
    }

    func isSuspended(typeID: ObjectIdentifier) -> Bool {
        slots.first(where: { $0.typeID == typeID })?.isSuspended ?? false
    }

    func update(context: SceneUpdateContext) {
        for slot in slots where !slot.isSuspended {
            slot.system.update(context: context)
        }
    }

    var count: Int { slots.count }
}
