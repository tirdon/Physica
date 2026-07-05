// Entity — the base scene object. RealityKit-flavored: identity + ComponentSet,
// with transform sugar layered over TransformComponent.

/// Anything that can stand in for entities in the scripted animation API.
/// `Entity` returns itself; `Animation` returns its targets.
import PhysicaMath
import PhysicaGeometry
import PhysicaTypesetting

@MainActor
public protocol Animatable {
    var animationTargets: [Entity] { get }
    /// Pending property changes carried into `scene.add(...)`/`scene.play(...)`.
    var carriedBlueprints: [AnimationPair] { get }
}

/// Transform access shared by `Entity` and `Animation`.
@MainActor
public protocol HasTransform {
    var transform: Transform { get nonmutating set }
}

public extension HasTransform {
    var position: Position {
        get { transform.position }
        nonmutating set { transform.position = newValue }
    }

    var orientation: Quaternion {
        get { transform.orientation }
        nonmutating set { transform.orientation = newValue }
    }

    var scale: SIMD3<Real> {
        get { transform.scale }
        nonmutating set { transform.scale = newValue }
    }
}

@MainActor
open class Entity: Animatable, HasTransform, Identifiable, Hashable {
    private static var nextID: UInt64 = 1

    /// Monotonic, deterministic within a run — no Foundation/UUID in the core.
    nonisolated public let id: UInt64

    public var components = ComponentSet()
    public var name: String = ""
    public internal(set) weak var parent: Entity?
    public package(set) weak var scene: Scene?

    /// Set once an entity is permanently removed: `Scene.insert` refuses to
    /// re-add a retired entity, so an `add` clip replayed by a scrub won't
    /// resurrect a one-shot tool (a consumed projection operator).
    public internal(set) var isRetired = false

    public init() {
        self.id = Entity.nextID
        Entity.nextID += 1
    }

    // MARK: Transform

    public var transform: Transform {
        get { components[TransformComponent.self]?.transform ?? .identity }
        set {
            var component = components[TransformComponent.self] ?? TransformComponent()
            component.transform = newValue
            components[TransformComponent.self] = component
        }
    }

    /// Transform composed through the parent chain.
    public var worldTransform: Transform {
        if let parent {
            return parent.worldTransform.concatenating(transform)
        }
        return transform
    }

    // MARK: Bounds

    /// Geometry bounds in local space; geometry-bearing subclasses override.
    open var localBounds: Bounds { .empty }

    /// Bounds in world space (empty local bounds collapse to the world position).
    public var worldBounds: Bounds { localBounds.transformed(by: worldTransform) }

    public var center: Position { worldBounds.center }

    /// World point → this entity's local space (updaters crossing spaces use this).
    public func convert(worldPosition: Position) -> Position {
        let world = worldTransform
        let unrotated = world.orientation.inverse.rotate(worldPosition - world.position)
        return Position(
            world.scale.x != 0 ? unrotated.x / world.scale.x : 0,
            world.scale.y != 0 ? unrotated.y / world.scale.y : 0,
            world.scale.z != 0 ? unrotated.z / world.scale.z : 0
        )
    }

    // MARK: Animatable

    public var animationTargets: [Entity] { [self] }
    public var carriedBlueprints: [AnimationPair] { [] }

    // MARK: Debug

    public var debugString: String {
        let kind = String(describing: type(of: self))
        let label = name.isEmpty ? "" : " '\(name)'"
        return "\(kind)\(label) pos\(fmt(transform.position)) \(components.debugString)"
    }

    // MARK: Hashable / Identifiable

    nonisolated public static func == (lhs: Entity, rhs: Entity) -> Bool {
        lhs.id == rhs.id
    }

    nonisolated public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
