// Animation blueprints — deferred descriptions of property changes.
//
// Entity animation methods build blueprints instead of mutating immediately; clips
// bake them into tracks at enqueue time, and tracks capture start values lazily at
// first playback so sequential clips compose.

@MainActor
public protocol AnimationBlueprint {
    var defaultDuration: Duration { get }
    var debugLabel: String { get }
    /// Creation animations (write/draw) introduce their target: `play` adds it
    /// to the scene if no earlier clip has — no separate `scene.add` needed.
    var introducesTarget: Bool { get }
    /// Erase animations remove their target from the scene when their window ends.
    var removesTargetAtEnd: Bool { get }

    func makeTrack(
        target: Entity,
        duration: TimeInterval,
        offset: TimeInterval,
        easing: Easing,
        in scene: Scene
    ) -> any AnimationTrackProtocol
}

public extension AnimationBlueprint {
    var defaultDuration: Duration { .seconds(1) }
    var introducesTarget: Bool { false }
    var removesTargetAtEnd: Bool { false }
}

// MARK: - Transform blueprints

struct MoveBlueprint: AnimationBlueprint {
    let destination: Position
    var debugLabel: String { "move(to: \(fmt(destination)))" }

    func makeTrack(
        target: Entity, duration: TimeInterval, offset: TimeInterval, easing: Easing, in scene: Scene
    ) -> any AnimationTrackProtocol {
        PropertyTrack<Position>(
            target: target, duration: duration, offset: offset, easing: easing,
            label: "\(name(of: target)).\(debugLabel)",
            read: { $0.position },
            write: { $0.position = $1 },
            resolveEnd: { _, _ in destination }
        )
    }
}

struct MoveToUnitBlueprint: AnimationBlueprint {
    let unit: Unit
    let padding: Real
    var debugLabel: String { "move(to: .\(unit))" }

    func makeTrack(
        target: Entity, duration: TimeInterval, offset: TimeInterval, easing: Easing, in scene: Scene
    ) -> any AnimationTrackProtocol {
        PropertyTrack<Position>(
            target: target, duration: duration, offset: offset, easing: easing,
            label: "\(name(of: target)).\(debugLabel)",
            read: { $0.position },
            write: { $0.position = $1 },
            resolveEnd: { [weak scene] entity, start in
                guard let scene else { return start }
                return Self.destination(
                    for: entity, unit: unit, padding: padding, frame: scene.frameBounds, start: start
                )
            }
        )
    }

    /// Axes named by the unit are pinned to the frame edge (inset by padding plus the
    /// entity's half-extent); unnamed axes keep their current coordinate.
    static func destination(for entity: Entity, unit: Unit, padding: Real, frame: Bounds, start: Position) -> Position {
        if unit == .center {
            return Position(frame.center.x, frame.center.y, start.z)
        }
        let direction = unit.vector
        let extents = entity.worldBounds.size / 2
        var destination = start
        if direction.x > 0 { destination.x = frame.max.x - padding - extents.x }
        if direction.x < 0 { destination.x = frame.min.x + padding + extents.x }
        if direction.y > 0 { destination.y = frame.max.y - padding - extents.y }
        if direction.y < 0 { destination.y = frame.min.y + padding + extents.y }
        return destination
    }

}

// MARK: - Grouped unit move

public extension Group {
    /// Bag builder that also accepts stored animation handles
    /// (`let bob = Circle().move(to: p)`): each item contributes its targets.
    convenience init(_ items: any Animatable...) {
        var members: [Entity] = []
        for item in items {
            for target in item.animationTargets where !members.contains(where: { $0 === target }) {
                members.append(target)
            }
        }
        self.init(children: members)
    }

    /// Moves the group's members to a frame edge **as one rigid unit**: the
    /// union of their bounds is pinned to the edge and every member shifts by
    /// the same delta, so relative layout (a pendulum's string length) survives:
    /// `scene.play(Group(pivot, string, bob).move(to: .bottom))`.
    /// The group can be a transient bag — it never needs to join the scene.
    /// Separate `entity.move(to:)` calls still pin each entity individually.
    @discardableResult
    func move(to unit: Unit, padding: Real = 0.5) -> Animation {
        let blueprint = GroupedMoveToUnitBlueprint(members: children, unit: unit, padding: padding)
        return Animation(pairs: children.map { AnimationPair(target: $0, blueprint: blueprint) })
    }
}

struct GroupedMoveToUnitBlueprint: AnimationBlueprint {
    let members: [Entity]
    let unit: Unit
    let padding: Real
    var debugLabel: String { "move(to: .\(unit))" }

    func makeTrack(
        target: Entity, duration: TimeInterval, offset: TimeInterval, easing: Easing, in scene: Scene
    ) -> any AnimationTrackProtocol {
        PropertyTrack<Position>(
            target: target, duration: duration, offset: offset, easing: easing,
            label: "\(name(of: target)).\(debugLabel)",
            read: { $0.position },
            write: { $0.position = $1 },
            // Each member's track resolves at clip begin — before any apply
            // has moved anything — so all members compute the same delta.
            resolveEnd: { [weak scene] _, start in
                guard let scene else { return start }
                return start + Self.delta(members: members, unit: unit, padding: padding, frame: scene.frameBounds)
            }
        )
    }

    /// Delta that pins the union of the members' bounds to the frame edge.
    static func delta(members: [Entity], unit: Unit, padding: Real, frame: Bounds) -> Position {
        var union = Bounds.empty
        for member in members {
            union = union.union(member.worldBounds)
        }
        var delta = Position(0, 0, 0)
        if unit == .center {
            delta = Position(frame.center.x - union.center.x, frame.center.y - union.center.y, 0)
        } else {
            let direction = unit.vector
            let extents = union.size / 2
            if direction.x > 0 { delta.x = frame.max.x - padding - extents.x - union.center.x }
            if direction.x < 0 { delta.x = frame.min.x + padding + extents.x - union.center.x }
            if direction.y > 0 { delta.y = frame.max.y - padding - extents.y - union.center.y }
            if direction.y < 0 { delta.y = frame.min.y + padding + extents.y - union.center.y }
        }
        return delta
    }
}

struct ShiftBlueprint: AnimationBlueprint {
    let delta: Position
    var debugLabel: String { "shift(\(fmt(delta)))" }

    func makeTrack(
        target: Entity, duration: TimeInterval, offset: TimeInterval, easing: Easing, in scene: Scene
    ) -> any AnimationTrackProtocol {
        PropertyTrack<Position>(
            target: target, duration: duration, offset: offset, easing: easing,
            label: "\(name(of: target)).\(debugLabel)",
            read: { $0.position },
            write: { $0.position = $1 },
            resolveEnd: { _, start in start + delta }
        )
    }
}

struct ScaleBlueprint: AnimationBlueprint {
    let factor: Real
    let isRelative: Bool
    var debugLabel: String { isRelative ? "scale(by: \(fmt(factor)))" : "scale(to: \(fmt(factor)))" }

    func makeTrack(
        target: Entity, duration: TimeInterval, offset: TimeInterval, easing: Easing, in scene: Scene
    ) -> any AnimationTrackProtocol {
        PropertyTrack<SIMD3<Real>>(
            target: target, duration: duration, offset: offset, easing: easing,
            label: "\(name(of: target)).\(debugLabel)",
            read: { $0.scale },
            write: { $0.scale = $1 },
            resolveEnd: { _, start in
                isRelative ? start * factor : SIMD3(factor, factor, factor)
            }
        )
    }
}

struct RotateBlueprint: AnimationBlueprint {
    let angle: Real
    let axis: Position
    var debugLabel: String { "rotate(by: \(fmt(angle)))" }

    func makeTrack(
        target: Entity, duration: TimeInterval, offset: TimeInterval, easing: Easing, in scene: Scene
    ) -> any AnimationTrackProtocol {
        SpinTrack(
            target: target, duration: duration, offset: offset, easing: easing,
            label: "\(name(of: target)).\(debugLabel)",
            angle: angle, axis: axis
        )
    }
}

// MARK: - Style blueprints

struct ColorBlueprint: AnimationBlueprint {
    let color: Color
    var debugLabel: String { "color(\(color.debugDescription))" }

    func makeTrack(
        target: Entity, duration: TimeInterval, offset: TimeInterval, easing: Easing, in scene: Scene
    ) -> any AnimationTrackProtocol {
        PropertyTrack<Color>(
            target: target, duration: duration, offset: offset, easing: easing,
            label: "\(name(of: target)).\(debugLabel)",
            read: { $0.components[RenderStyleComponent.self]?.color ?? .white },
            write: { entity, value in
                var style = entity.components[RenderStyleComponent.self] ?? RenderStyleComponent()
                style.color = value
                if style.strokeColor != nil { style.strokeColor = value }
                entity.components[RenderStyleComponent.self] = style
            },
            resolveEnd: { _, _ in color }
        )
    }
}

struct FadeBlueprint: AnimationBlueprint {
    let opacity: Real
    var debugLabel: String { "fade(to: \(fmt(opacity, decimals: 2)))" }

    func makeTrack(
        target: Entity, duration: TimeInterval, offset: TimeInterval, easing: Easing, in scene: Scene
    ) -> any AnimationTrackProtocol {
        PropertyTrack<Real>(
            target: target, duration: duration, offset: offset, easing: easing,
            label: "\(name(of: target)).\(debugLabel)",
            read: { $0.components[RenderStyleComponent.self]?.opacity ?? 1 },
            write: { entity, value in
                var style = entity.components[RenderStyleComponent.self] ?? RenderStyleComponent()
                style.opacity = value
                entity.components[RenderStyleComponent.self] = style
            },
            resolveEnd: { _, _ in opacity }
        )
    }
}
