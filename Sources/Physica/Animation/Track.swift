// Animation tracks — the scrub-safe playback units inside a clip.
//
// Contract: `begin` captures start state once (idempotent, cached forever so
// replays after rewind are deterministic); `apply(at:)` is a pure function of
// clip-local time; `rewind` restores the pre-clip state when scrubbing backward.

import PhysicaMath
import PhysicaGeometry
import PhysicaTypesetting

@MainActor
public protocol AnimationTrackProtocol: AnyObject {
    /// Active duration in seconds (excluding `offset`).
    var duration: TimeInterval { get }
    /// Start delay within the owning clip.
    var offset: TimeInterval { get }
    var label: String { get }

    /// Captures start state; idempotent — called the first time the clip is reached.
    func begin(in scene: Scene)
    /// Applies state for clip-local time (callers clamp to 0...clip duration).
    func apply(at clipTime: TimeInterval, in scene: Scene)
    /// Undoes the track when scrubbing back before the clip.
    func rewind(in scene: Scene)
}

extension AnimationTrackProtocol {
    /// Normalized eased progress for a clip-local time.
    package func progress(at clipTime: TimeInterval, easing: Easing) -> Real {
        let local = clipTime - offset
        if local <= 0 { return duration <= 0 && clipTime >= offset ? easing.apply(1) : 0 }
        if duration <= 0 { return easing.apply(1) }
        return easing.apply(min(max(local / duration, 0), 1))
    }
}
