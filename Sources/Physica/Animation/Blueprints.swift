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
