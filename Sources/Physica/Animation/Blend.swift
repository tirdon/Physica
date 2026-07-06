// Blend — additive animation layering. The default (`.replace`) track writes
// absolute values from its begin-captured start, so overlapping animations on
// the same property hand off rather than combine. An `.additive` animation
// contributes only its *delta*: each frame it applies the difference between
// its new and last contribution, so it stacks on top of other additive
// animations and system/updater writers — an idle wobble under a directed
// shift, a recoil on a moving body.
//
//   scene.play(group: bob.shift(2.i), bob.shift(0.4.j, blend: .additive))
//
// Notes on composition: additive⊕additive and additive⊕system writes sum
// exactly; a concurrent `.replace` animation on the same property overwrites
// the shared base each frame and wins (mixing modes on one property is
// author's discretion). Scrub-safe: contributions are self-correcting in t
// (re-applying the same time adds zero) and rewind subtracts the remainder.

import PhysicaFoundation
import PhysicaTypesetting

public enum BlendMode: Sendable {
    /// Absolute interpolation from the begin-captured start (the default).
    case replace
    /// Contribute a delta on top of whatever else drives the property.
    case additive
}

@MainActor
public extension Animatable {
    /// `shift` with an explicit blend mode; `.additive` layers the offset on
    /// top of other animations and system writers instead of replacing them.
    @discardableResult
    func shift(_ delta: Position, blend: BlendMode) -> Animation {
        switch blend {
        case .replace:
            return shift(delta)
        case .additive:
            return Animation(pairs: carriedBlueprints + animationTargets.map {
                AnimationPair(target: $0, blueprint: AdditiveShiftBlueprint(delta: delta))
            })
        }
    }

    /// `rotate` with an explicit blend mode; `.additive` layers the turn.
    @discardableResult
    func rotate(by angle: Real, axis: Position = 1.k, blend: BlendMode) -> Animation {
        switch blend {
        case .replace:
            return rotate(by: angle, axis: axis)
        case .additive:
            return Animation(pairs: carriedBlueprints + animationTargets.map {
                AnimationPair(target: $0, blueprint: AdditiveSpinBlueprint(angle: angle, axis: axis))
            })
        }
    }
}

// MARK: - Blueprints

struct AdditiveShiftBlueprint: AnimationBlueprint {
    let delta: Position
    var debugLabel: String { "shift(\(fmt(delta)), blend: .additive)" }

    func makeTrack(
        target: Entity, duration: TimeInterval, offset: TimeInterval, easing: Easing, in scene: Scene
    ) -> any AnimationTrackProtocol {
        AdditiveShiftTrack(
            target: target, delta: delta, duration: duration, offset: offset, easing: easing,
            label: "\(name(of: target)).\(debugLabel)"
        )
    }
}

struct AdditiveSpinBlueprint: AnimationBlueprint {
    let angle: Real
    let axis: Position
    var debugLabel: String { "rotate(by: \(fmt(angle, decimals: 2)), blend: .additive)" }

    func makeTrack(
        target: Entity, duration: TimeInterval, offset: TimeInterval, easing: Easing, in scene: Scene
    ) -> any AnimationTrackProtocol {
        AdditiveSpinTrack(
            target: target, angle: angle, axis: axis, duration: duration, offset: offset,
            easing: easing, label: "\(name(of: target)).\(debugLabel)"
        )
    }
}

// MARK: - Tracks

/// Applies the *difference* between its new and last positional contribution,
/// so concurrent writers on the same property sum instead of clobbering.
@MainActor
final class AdditiveShiftTrack: AnimationTrackProtocol {
    let duration: TimeInterval
    let offset: TimeInterval
    let label: String
    private let easing: Easing
    private let target: Entity
    private let delta: Position
    private var lastContribution = Position.zero

    init(
        target: Entity, delta: Position, duration: TimeInterval, offset: TimeInterval,
        easing: Easing, label: String
    ) {
        self.target = target
        self.delta = delta
        self.duration = max(duration, 0)
        self.offset = max(offset, 0)
        self.easing = easing
        self.label = label
    }

    func begin(in scene: Scene) {}   // nothing to capture — deltas carry no base

    func apply(at clipTime: TimeInterval, in scene: Scene) {
        let contribution = delta * progress(at: clipTime, easing: easing)
        target.position += contribution - lastContribution
        lastContribution = contribution
    }

    func rewind(in scene: Scene) {
        target.position -= lastContribution
        lastContribution = .zero
    }
}

/// Additive rotation: applies incremental turns about `axis`, composing with
/// whatever else drives the orientation.
@MainActor
final class AdditiveSpinTrack: AnimationTrackProtocol {
    let duration: TimeInterval
    let offset: TimeInterval
    let label: String
    private let easing: Easing
    private let target: Entity
    private let angle: Real
    private let axis: Position
    private var lastAngle: Real = 0

    init(
        target: Entity, angle: Real, axis: Position, duration: TimeInterval,
        offset: TimeInterval, easing: Easing, label: String
    ) {
        self.target = target
        self.angle = angle
        self.axis = axis
        self.duration = max(duration, 0)
        self.offset = max(offset, 0)
        self.easing = easing
        self.label = label
    }

    func begin(in scene: Scene) {}

    func apply(at clipTime: TimeInterval, in scene: Scene) {
        let current = angle * progress(at: clipTime, easing: easing)
        target.orientation = target.orientation * Quaternion(angle: current - lastAngle, axis: axis)
        lastAngle = current
    }

    func rewind(in scene: Scene) {
        target.orientation = target.orientation * Quaternion(angle: -lastAngle, axis: axis)
        lastAngle = 0
    }
}
