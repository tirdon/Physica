// .highlight(entity) — a neon border around the target's bounds, in one of two
// styles: `.circumscribe` (default — the border draws itself fully on, holds a
// beat so the eye can land, then the whole loop fades away) or `.chase` (the
// loading-loop: the stroke head runs one full lap while the tail follows
// behind, so the loop dissolves from its own start). Either way nothing
// remains at the end. The border is a transient entity: added when the clip
// starts, removed when it completes (scrub-safe both ways).

import PhysicaFoundation
import PhysicaTypesetting

/// Choreography of the `.highlight` border. Top-level (the AxisOptions
/// precedent): a pure value, no scene coupling.
public enum HighlightStyle: Sendable, Equatable {
    /// Draw on → hold → fade out (the default).
    case circumscribe
    /// The loading-loop chase: head runs a lap, tail catches it at the end.
    case chase
}

public extension Animation {
    /// Neon border around `target`'s bounds (captured at clip start):
    /// `scene.play(.highlight(entity))`. No `scene.add` needed — the border
    /// introduces itself and leaves the scene when the effect finishes.
    static func highlight(
        _ target: Entity,
        color: Color = Color(hex: 0x53F0FF),
        padding: Real = 0.3,
        style: HighlightStyle = .circumscribe
    ) -> Animation {
        let border = PathEntity()
        border.name = "highlight"
        border.components[RenderStyleComponent.self] = RenderStyleComponent(
            color: color,
            strokeColor: color,
            strokeWidth: 0.035,
            cap: .round,
            isFilled: false,
            neon: true
        )
        border.components[PathComponent.self] = PathComponent(strokeProgress: 0)
        return Animation(pairs: [AnimationPair(
            target: border,
            blueprint: HighlightBlueprint(subject: target, padding: padding, style: style)
        )])
    }

    /// Optional-tolerant `.highlight`: nil target → nil animation.
    static func highlight(
        _ target: Entity?,
        color: Color = Color(hex: 0x53F0FF),
        padding: Real = 0.3,
        style: HighlightStyle = .circumscribe
    ) -> Animation? {
        guard let target else { return nil }
        // The `: Animation` annotation is load-bearing: with the defaulted
        // args, it disambiguates the non-optional `highlight` from this one.
        let animation: Animation = highlight(target, color: color, padding: padding, style: style)
        return animation
    }
}

struct HighlightBlueprint: AnimationBlueprint {
    let subject: Entity
    let padding: Real
    let style: HighlightStyle

    var debugLabel: String {
        style == .chase
            ? "highlight(\(name(of: subject)), .chase)"
            : "highlight(\(name(of: subject)))"
    }
    var defaultDuration: Duration { .seconds(1.2) }
    var introducesTarget: Bool { true }
    var removesTargetAtEnd: Bool { true }

    func makeTrack(
        target: Entity, duration: TimeInterval, offset: TimeInterval, easing: Easing, in scene: Scene
    ) -> any AnimationTrackProtocol {
        HighlightTrack(
            border: target, subject: subject, padding: padding, style: style,
            duration: duration, offset: offset, easing: easing,
            label: "\(name(of: subject)).\(debugLabel)"
        )
    }
}

@MainActor
final class HighlightTrack: AnimationTrackProtocol {
    let duration: TimeInterval
    let offset: TimeInterval
    let label: String
    private let easing: Easing
    private let border: Entity
    private let subject: Entity
    private let padding: Real
    private let style: HighlightStyle
    private var hasBegun = false

    /// Circumscribe: the border finishes drawing at 35% of the window, stays
    /// fully lit through 70%, then fades to nothing at the end.
    private static let drawWindow: Real = 0.35
    private static let holdUntil: Real = 0.7

    /// Chase: the head finishes its lap at 62% of the window; the tail leaves
    /// at 38% and catches up exactly at the end — one chase, then nothing.
    private static let lapWindow: Real = 0.62

    init(
        border: Entity, subject: Entity, padding: Real, style: HighlightStyle,
        duration: TimeInterval, offset: TimeInterval, easing: Easing, label: String
    ) {
        self.border = border
        self.subject = subject
        self.padding = padding
        self.style = style
        self.duration = max(duration, 0)
        self.offset = max(offset, 0)
        self.easing = easing
        self.label = label
    }

    func begin(in scene: Scene) {
        guard !hasBegun else { return }
        hasBegun = true
        guard let pathEntity = border as? PathEntity else { return }
        let bounds = subject.worldBounds
        let width = bounds.size.x + 2 * padding
        let height = bounds.size.y + 2 * padding
        let radius = Swift.min(0.5, Swift.min(width, height) * 0.35)
        // World-space path (the border keeps an identity transform).
        pathEntity.path = Path.roundedRect(
            width: width, height: height, cornerRadius: radius,
            center: SIMD2(bounds.center.x, bounds.center.y)
        )
    }

    func apply(at clipTime: TimeInterval, in scene: Scene) {
        guard var component = border.components[PathComponent.self] else { return }
        let raw = progress(at: clipTime, easing: .linear)
        switch style {
        case .circumscribe:
            component.strokeProgress = easing.apply(Swift.min(raw / Self.drawWindow, 1))
            border.components[PathComponent.self] = component
            guard var styleComponent = border.components[RenderStyleComponent.self] else { return }
            let fade = Swift.max((raw - Self.holdUntil) / (1 - Self.holdUntil), 0)
            styleComponent.opacity = 1 - easing.apply(Swift.min(fade, 1))
            border.components[RenderStyleComponent.self] = styleComponent
        case .chase:
            component.strokeProgress = easing.apply(Swift.min(raw / Self.lapWindow, 1))
            component.strokeStart = easing.apply(Swift.max((raw - (1 - Self.lapWindow)) / Self.lapWindow, 0))
            border.components[PathComponent.self] = component
        }
    }

    func rewind(in scene: Scene) {
        if var component = border.components[PathComponent.self] {
            component.strokeProgress = 0
            component.strokeStart = 0
            border.components[PathComponent.self] = component
        }
        if var styleComponent = border.components[RenderStyleComponent.self] {
            styleComponent.opacity = 1
            border.components[RenderStyleComponent.self] = styleComponent
        }
    }
}
