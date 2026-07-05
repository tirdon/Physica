// .highlight(entity) — a neon border chase, like a loading loop: the stroke
// head runs one full lap around the target's bounds while the tail follows
// behind, so the loop draws itself on and dissolves from its own start —
// nothing remains at the end. The border is a transient entity: added when
// the clip starts, removed when it completes (scrub-safe both ways).

import PhysicaFoundation
import PhysicaTypesetting

public extension Animation {
    /// Neon loading-loop around `target`'s bounds (captured at clip start):
    /// `scene.play(.highlight(entity))`. No `scene.add` needed — the border
    /// introduces itself and leaves the scene when the loop finishes.
    static func highlight(
        _ target: Entity,
        color: Color = Color(hex: 0x53F0FF),
        padding: Real = 0.3
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
            blueprint: HighlightBlueprint(subject: target, padding: padding)
        )])
    }
}

struct HighlightBlueprint: AnimationBlueprint {
    let subject: Entity
    let padding: Real

    var debugLabel: String { "highlight(\(name(of: subject)))" }
    var defaultDuration: Duration { .seconds(1.2) }
    var introducesTarget: Bool { true }
    var removesTargetAtEnd: Bool { true }

    func makeTrack(
        target: Entity, duration: TimeInterval, offset: TimeInterval, easing: Easing, in scene: Scene
    ) -> any AnimationTrackProtocol {
        HighlightTrack(
            border: target, subject: subject, padding: padding,
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
    private var hasBegun = false

    /// The head finishes its lap at 62% of the window; the tail leaves at 38%
    /// and catches up exactly at the end — one chase, then nothing.
    private static let lapWindow: Real = 0.62

    init(
        border: Entity, subject: Entity, padding: Real,
        duration: TimeInterval, offset: TimeInterval, easing: Easing, label: String
    ) {
        self.border = border
        self.subject = subject
        self.padding = padding
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
        component.strokeProgress = easing.apply(Swift.min(raw / Self.lapWindow, 1))
        component.strokeStart = easing.apply(Swift.max((raw - (1 - Self.lapWindow)) / Self.lapWindow, 0))
        border.components[PathComponent.self] = component
    }

    func rewind(in scene: Scene) {
        guard var component = border.components[PathComponent.self] else { return }
        component.strokeProgress = 0
        component.strokeStart = 0
        border.components[PathComponent.self] = component
    }
}
