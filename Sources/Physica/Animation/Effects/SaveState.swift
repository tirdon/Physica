// Manim-style save/restore: `saveState()` is a 0-duration clip that captures
// the targets' transforms at that point of the TIMELINE (not at script-build
// time — the state usually only exists during playback, e.g. mid-swing);
// `restoreState()` animates back to the capture. Both are scrub-safe: the
// capture lives in a SavedStateComponent that save's rewind removes again.

/// Timeline-captured transform, written by `saveState()` and read
/// (non-destructively — repeated restores work) by `restoreState()`.
import PhysicaMath
import PhysicaGeometry
import PhysicaTypesetting

public struct SavedStateComponent: Component {
    public var transform: Transform

    public init(transform: Transform) {
        self.transform = transform
    }

    public var debugString: String { "saved(\(transform.debugDescription))" }
}

public extension Animatable {
    /// Captures the target's transform at this point of the timeline
    /// (0-duration clip): `scene.play(entity.saveState())`.
    @discardableResult
    func saveState() -> Animation {
        Animation(pairs: animationTargets.map {
            AnimationPair(target: $0, blueprint: SaveStateBlueprint())
        })
    }

    /// Animates the target back to its last `saveState()` capture (a no-op
    /// when there is none): `scene.play(entity.restoreState())`.
    @discardableResult
    func restoreState() -> Animation {
        Animation(pairs: animationTargets.map {
            AnimationPair(target: $0, blueprint: RestoreStateBlueprint())
        })
    }
}

public extension Group {
    /// Captures every member's transform (the bag itself stays untouched):
    /// `scene.play(pendulum.saveState())`.
    @discardableResult
    func saveState() -> Animation {
        Animation(pairs: children.map {
            AnimationPair(target: $0, blueprint: SaveStateBlueprint())
        })
    }

    /// Animates every member back to its capture:
    /// `scene.play(pendulum.restoreState())`.
    @discardableResult
    func restoreState() -> Animation {
        Animation(pairs: children.map {
            AnimationPair(target: $0, blueprint: RestoreStateBlueprint())
        })
    }
}

struct SaveStateBlueprint: AnimationBlueprint {
    var debugLabel: String { "saveState()" }
    var defaultDuration: Duration { .zero }

    func makeTrack(
        target: Entity, duration: TimeInterval, offset: TimeInterval, easing: Easing, in scene: Scene
    ) -> any AnimationTrackProtocol {
        SaveStateTrack(target: target, offset: offset, label: "\(name(of: target)).\(debugLabel)")
    }
}

struct RestoreStateBlueprint: AnimationBlueprint {
    var debugLabel: String { "restoreState()" }

    func makeTrack(
        target: Entity, duration: TimeInterval, offset: TimeInterval, easing: Easing, in scene: Scene
    ) -> any AnimationTrackProtocol {
        PropertyTrack<Transform>(
            target: target, duration: duration, offset: offset, easing: easing,
            label: "\(name(of: target)).\(debugLabel)",
            read: { $0.transform },
            write: { $0.transform = $1 },
            resolveEnd: { entity, start in
                entity.components[SavedStateComponent.self]?.transform ?? start
            }
        )
    }
}

@MainActor
final class SaveStateTrack: AnimationTrackProtocol {
    let duration: TimeInterval = 0
    let offset: TimeInterval
    let label: String

    private let target: Entity
    private var hasBegun = false
    private var captured: Transform?
    /// The component before this clip (nil = none) — rewind restores it.
    private var previous: SavedStateComponent?

    init(target: Entity, offset: TimeInterval, label: String) {
        self.target = target
        self.offset = max(offset, 0)
        self.label = label
    }

    func begin(in scene: Scene) {
        guard !hasBegun else { return }
        hasBegun = true
        captured = target.transform
        previous = target.components[SavedStateComponent.self]
    }

    func apply(at clipTime: TimeInterval, in scene: Scene) {
        guard let captured else { return }
        if clipTime >= offset {
            target.components[SavedStateComponent.self] = SavedStateComponent(transform: captured)
        } else {
            target.components[SavedStateComponent.self] = previous
        }
    }

    func rewind(in scene: Scene) {
        target.components[SavedStateComponent.self] = previous
    }
}
