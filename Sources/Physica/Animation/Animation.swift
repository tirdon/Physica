// Animation — the currency type of the scripted API.
//
// Entity animation methods return `Animation` descriptors instead of mutating;
// `scene.add/play/wait/pause` also return `Animation`, so everything composes in
// `AnimationBuilder` blocks. An `Animation` forwards transform access to its first
// target, which is why `let bob = Circle().move(to: p)` still behaves like the circle.

@MainActor
public struct Animation: Animatable, HasTransform {
    public internal(set) var pairs: [(target: Entity, blueprint: any AnimationBlueprint)]
    /// nil → resolved by `play(for:)`, else the blueprint default, else 1 s.
    public var duration: Duration?
    /// Start delay within the owning clip.
    public var offset: Duration
    public var easing: Easing?

    public init(
        pairs: [(target: Entity, blueprint: any AnimationBlueprint)],
        duration: Duration? = nil,
        offset: Duration = .zero,
        easing: Easing? = nil
    ) {
        self.pairs = pairs
        self.duration = duration
        self.offset = offset
        self.easing = easing
    }

    /// `Animation(triangle.shift(-1.i), for: 2.s, offset: 1.s)` — the spec's wrapper.
    public init(_ animation: Animation, for duration: Duration, offset: Duration = .zero, easing: Easing? = nil) {
        self.pairs = animation.pairs
        self.duration = duration
        self.offset = offset
        self.easing = easing ?? animation.easing
    }

    // MARK: Animatable

    public var animationTargets: [Entity] {
        var seen = Set<UInt64>()
        var unique: [Entity] = []
        for pair in pairs where seen.insert(pair.target.id).inserted {
            unique.append(pair.target)
        }
        return unique
    }

    public var carriedBlueprints: [(target: Entity, blueprint: any AnimationBlueprint)] { pairs }

    // MARK: HasTransform / components (forwarded to the primary target)

    public var transform: Transform {
        get { pairs.first?.target.transform ?? .identity }
        nonmutating set { pairs.first?.target.transform = newValue }
    }

    /// `let bob = Circle().move(to: p)` keeps behaving like the circle:
    /// component access flows through to the underlying entity.
    public var components: ComponentSet {
        get { pairs.first?.target.components ?? ComponentSet() }
        nonmutating set { pairs.first?.target.components = newValue }
    }

    public var debugString: String {
        let labels = pairs.map { "\(name(of: $0.target)).\($0.blueprint.debugLabel)" }
        return "Animation[" + labels.joined(separator: ", ") + "]"
    }
}

@MainActor
func name(of entity: Entity) -> String {
    entity.name.isEmpty ? String(describing: type(of: entity)) : entity.name
}

// MARK: - Factory surface

public extension Animatable {
    private func animation(_ blueprint: any AnimationBlueprint) -> Animation {
        Animation(pairs: animationTargets.map { (target: $0, blueprint: blueprint) })
    }

    /// Animate to an absolute position.
    @discardableResult
    func move(to position: Position) -> Animation {
        animation(MoveBlueprint(destination: position))
    }

    /// Animate to a scene edge/corner (resolved against the camera frame at clip start).
    @discardableResult
    func move(to unit: Unit, padding: Real = 0.5) -> Animation {
        animation(MoveToUnitBlueprint(unit: unit, padding: padding))
    }

    /// Animate by a relative offset (resolved at clip start).
    @discardableResult
    func shift(_ delta: Position) -> Animation {
        animation(ShiftBlueprint(delta: delta))
    }

    @discardableResult
    func scale(to factor: Real) -> Animation {
        animation(ScaleBlueprint(factor: factor, isRelative: false))
    }

    @discardableResult
    func scale(by factor: Real) -> Animation {
        animation(ScaleBlueprint(factor: factor, isRelative: true))
    }

    /// Spin by an angle (exact, supports multi-turn — not shortest-arc slerp).
    @discardableResult
    func rotate(by angle: Real, axis: Position = 1.k) -> Animation {
        animation(RotateBlueprint(angle: angle, axis: axis))
    }

    @discardableResult
    func setColor(to color: Color) -> Animation {
        animation(ColorBlueprint(color: color))
    }

    @discardableResult
    func fade(to opacity: Real) -> Animation {
        animation(FadeBlueprint(opacity: opacity))
    }
}

// MARK: - Result builder

@resultBuilder
@MainActor
public enum AnimationBuilder {
    public static func buildExpression(_ animation: Animation) -> [Animation] { [animation] }
    public static func buildExpression(_ animations: [Animation]) -> [Animation] { animations }
    public static func buildBlock(_ parts: [Animation]...) -> [Animation] { parts.flatMap { $0 } }
    public static func buildArray(_ parts: [[Animation]]) -> [Animation] { parts.flatMap { $0 } }
    public static func buildOptional(_ part: [Animation]?) -> [Animation] { part ?? [] }
    public static func buildEither(first: [Animation]) -> [Animation] { first }
    public static func buildEither(second: [Animation]) -> [Animation] { second }
}
