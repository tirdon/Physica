// Per-frame derived-state updaters (the confirmed hybrid design).
//
// `string.updater = { $0.end = bob.position }`   — Manim add_updater style
// `string.bind(\.end, to: bob, \.position)`      — type-safe KeyPath form
//   (Position binds are world-aware, and Animation handles resolve to their
//   first target, so the pendulum line is exactly this one call.)
//
// Both store into UpdaterComponent; the scene runs all updaters after the timeline
// and systems each frame, and once after every seek, so derived geometry is always
// consistent with whatever moved its sources.

import PhysicaFoundation
import PhysicaTypesetting

public struct UpdaterComponent: Component {
    struct Entry {
        let id: UInt64
        let raw: Any
        let run: @MainActor (Entity) -> Void
    }

    var entries: [Entry] = []

    public init() {}

    public var debugString: String { "updaters(\(entries.count))" }
}

@MainActor
private var nextUpdaterID: UInt64 = 1

public extension Animatable where Self: Entity {
    /// Single-updater convenience. Setting replaces all existing updaters;
    /// setting `nil` removes them.
    var updater: (@MainActor (Self) -> Void)? {
        get {
            components[UpdaterComponent.self]?.entries.last?.raw as? @MainActor (Self) -> Void
        }
        set {
            guard let newValue else {
                components.remove(UpdaterComponent.self)
                return
            }
            components[UpdaterComponent.self] = UpdaterComponent()
            addUpdater(newValue)
        }
    }

    /// Appends an updater without disturbing existing ones.
    @discardableResult
    func addUpdater(_ run: @escaping @MainActor (Self) -> Void) -> UInt64 {
        var component = components[UpdaterComponent.self] ?? UpdaterComponent()
        let id = nextUpdaterID
        nextUpdaterID += 1
        component.entries.append(
            UpdaterComponent.Entry(id: id, raw: run) { entity in
                guard let typed = entity as? Self else { return }
                run(typed)
            }
        )
        components[UpdaterComponent.self] = component
        return id
    }

    func removeUpdater(id: UInt64) {
        guard var component = components[UpdaterComponent.self] else { return }
        component.entries.removeAll { $0.id == id }
        if component.entries.isEmpty {
            components.remove(UpdaterComponent.self)
        } else {
            components[UpdaterComponent.self] = component
        }
    }

    /// Keeps `keyPath` synced from `source[keyPath: sourceKeyPath]` every frame.
    @discardableResult
    func bind<S: Entity, V>(
        _ keyPath: ReferenceWritableKeyPath<Self, V>,
        to source: S,
        _ sourceKeyPath: KeyPath<S, V>
    ) -> UInt64 {
        rawBind(keyPath, source: source, sourceKeyPath)
    }

    /// Position-valued binds sync **across spaces**: the source value is read
    /// in the source's parent space (where `position` lives — world, for scene
    /// roots) and written converted into the target's local space. Root to
    /// root it is a plain copy; it stays correct once the target — or a group
    /// move enclosing it — acquires its own transform:
    /// `string.bind(\.end, to: bob, \.position)`.
    @discardableResult
    func bind<S: Entity>(
        _ keyPath: ReferenceWritableKeyPath<Self, Position>,
        to source: S,
        _ sourceKeyPath: KeyPath<S, Position>
    ) -> UInt64 {
        positionBind(keyPath, source: source, sourceKeyPath)
    }

    /// Animation handles work as sources too — `let bob = Circle().move(to: p)`
    /// keeps behaving like the circle: the bind follows the first animation
    /// target. Returns 0 (no updater installed) when the source has none.
    @discardableResult
    func bind<V>(
        _ keyPath: ReferenceWritableKeyPath<Self, V>,
        to source: any Animatable,
        _ sourceKeyPath: KeyPath<Entity, V>
    ) -> UInt64 {
        guard let entity = source.animationTargets.first else { return 0 }
        return rawBind(keyPath, source: entity, sourceKeyPath)
    }

    /// Animation-handle source, Position-valued (world-aware like the entity form).
    @discardableResult
    func bind(
        _ keyPath: ReferenceWritableKeyPath<Self, Position>,
        to source: any Animatable,
        _ sourceKeyPath: KeyPath<Entity, Position>
    ) -> UInt64 {
        guard let entity = source.animationTargets.first else { return 0 }
        return positionBind(keyPath, source: entity, sourceKeyPath)
    }

    /// Non-overloaded workers behind `bind` (the overload set could otherwise
    /// re-enter itself through the existential/optional conversions).
    private func rawBind<S: Entity, V>(
        _ keyPath: ReferenceWritableKeyPath<Self, V>,
        source: S,
        _ sourceKeyPath: KeyPath<S, V>
    ) -> UInt64 {
        addUpdater { [weak source] target in
            guard let source else { return }
            target[keyPath: keyPath] = source[keyPath: sourceKeyPath]
        }
    }

    private func positionBind<S: Entity>(
        _ keyPath: ReferenceWritableKeyPath<Self, Position>,
        source: S,
        _ sourceKeyPath: KeyPath<S, Position>
    ) -> UInt64 {
        addUpdater { [weak source] target in
            guard let source else { return }
            let value = source[keyPath: sourceKeyPath]
            let world = source.parent?.worldTransform.applying(to: value) ?? value
            target[keyPath: keyPath] = target.convert(worldPosition: world)
        }
    }
}
