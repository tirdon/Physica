// Per-frame derived-state updaters (the confirmed hybrid design).
//
// `string.updater = { $0.end = bob.position }`   — Manim add_updater style
// `string.bind(\.end, to: bob, \.position)`      — type-safe KeyPath form
//
// Both store into UpdaterComponent; the scene runs all updaters after the timeline
// and systems each frame, and once after every seek, so derived geometry is always
// consistent with whatever moved its sources.

public struct UpdaterComponent: Component {
    public struct Entry {
        public let id: UInt64
        let raw: Any
        let run: @MainActor (Entity) -> Void
    }

    public internal(set) var entries: [Entry] = []

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
        addUpdater { [weak source] target in
            guard let source else { return }
            target[keyPath: keyPath] = source[keyPath: sourceKeyPath]
        }
    }
}
