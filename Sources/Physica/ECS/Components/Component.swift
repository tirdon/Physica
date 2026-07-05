// Component protocol and per-entity type-keyed storage.
//
// Components are plain values confined to MainActor entities, so the protocol has
// no Sendable requirement — UpdaterComponent legally stores @MainActor closures.

import PhysicaFoundation
import PhysicaTypesetting

public protocol Component {
    /// Stable description used by tests. Default falls back to reflection;
    /// components asserted in tests override with fmt()-based output.
    var debugString: String { get }
}

public extension Component {
    var debugString: String { String(describing: self) }
}

/// Type-keyed component storage, RealityKit-style: `entity.components[X.self]`.
public struct ComponentSet {
    private var storage: [ObjectIdentifier: any Component] = [:]

    public init() {}

    public subscript<T: Component>(_ type: T.Type) -> T? {
        get { storage[ObjectIdentifier(type)] as? T }
        set { storage[ObjectIdentifier(type)] = newValue }
    }

    public mutating func set<T: Component>(_ component: T) {
        storage[ObjectIdentifier(T.self)] = component
    }

    public mutating func remove<T: Component>(_ type: T.Type) {
        storage[ObjectIdentifier(type)] = nil
    }

    public func has<T: Component>(_ type: T.Type) -> Bool {
        storage[ObjectIdentifier(type)] != nil
    }

    public var count: Int { storage.count }

    /// Sorted component type names, "Component" suffix stripped: `[RenderStyle, Transform]`.
    public var typeNames: [String] {
        storage.values
            .map { name in
                var n = String(describing: type(of: name))
                if n.hasSuffix("Component") { n.removeLast("Component".count) }
                return n
            }
            .sorted()
    }

    public var debugString: String {
        "[" + typeNames.joined(separator: ", ") + "]"
    }
}
