// Animation tracks — the scrub-safe playback units inside a clip.
//
// Contract: `begin` captures start state once (idempotent, cached forever so
// replays after rewind are deterministic); `apply(at:)` is a pure function of
// clip-local time; `rewind` restores the pre-clip state when scrubbing backward.

public struct Keyframe<Value: Interpolatable>: Sendable where Value: Sendable {
    public var time: TimeInterval
    public var value: Value
    public var easing: Easing

    public init(time: TimeInterval, value: Value, easing: Easing = .smooth) {
        self.time = time
        self.value = value
        self.easing = easing
    }
}

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
    func progress(at clipTime: TimeInterval, easing: Easing) -> Real {
        let local = clipTime - offset
        if local <= 0 { return duration <= 0 && clipTime >= offset ? easing.apply(1) : 0 }
        if duration <= 0 { return easing.apply(1) }
        return easing.apply(min(max(local / duration, 0), 1))
    }
}

// MARK: - Generic property track

@MainActor
final class PropertyTrack<Value: Interpolatable>: AnimationTrackProtocol {
    let duration: TimeInterval
    let offset: TimeInterval
    let label: String
    private let easing: Easing
    private let target: Entity
    private let read: (Entity) -> Value
    private let write: (Entity, Value) -> Void
    private let resolveEnd: (Entity, Value) -> Value

    private var startValue: Value?
    private var endValue: Value?

    init(
        target: Entity,
        duration: TimeInterval,
        offset: TimeInterval,
        easing: Easing,
        label: String,
        read: @escaping (Entity) -> Value,
        write: @escaping (Entity, Value) -> Void,
        resolveEnd: @escaping (Entity, Value) -> Value
    ) {
        self.target = target
        self.duration = max(duration, 0)
        self.offset = max(offset, 0)
        self.easing = easing
        self.label = label
        self.read = read
        self.write = write
        self.resolveEnd = resolveEnd
    }

    func begin(in scene: Scene) {
        guard startValue == nil else { return }
        let start = read(target)
        startValue = start
        endValue = resolveEnd(target, start)
    }

    func apply(at clipTime: TimeInterval, in scene: Scene) {
        guard let start = startValue, let end = endValue else { return }
        let t = progress(at: clipTime, easing: easing)
        write(target, Value.lerp(start, end, t))
    }

    func rewind(in scene: Scene) {
        if let start = startValue {
            write(target, start)
        }
    }
}

// MARK: - Spin track (exact multi-turn rotation, not shortest-arc slerp)

@MainActor
final class SpinTrack: AnimationTrackProtocol {
    let duration: TimeInterval
    let offset: TimeInterval
    let label: String
    private let easing: Easing
    private let target: Entity
    private let angle: Real
    private let axis: Position

    private var startOrientation: Quaternion?

    init(
        target: Entity, duration: TimeInterval, offset: TimeInterval, easing: Easing,
        label: String, angle: Real, axis: Position
    ) {
        self.target = target
        self.duration = max(duration, 0)
        self.offset = max(offset, 0)
        self.easing = easing
        self.label = label
        self.angle = angle
        self.axis = axis
    }

    func begin(in scene: Scene) {
        guard startOrientation == nil else { return }
        startOrientation = target.orientation
    }

    func apply(at clipTime: TimeInterval, in scene: Scene) {
        guard let start = startOrientation else { return }
        let t = progress(at: clipTime, easing: easing)
        target.orientation = start * Quaternion(angle: angle * t, axis: axis)
    }

    func rewind(in scene: Scene) {
        if let start = startOrientation {
            target.orientation = start
        }
    }
}

// MARK: - Keyframe track

@MainActor
final class KeyframeTrack<Value: Interpolatable & Sendable>: AnimationTrackProtocol {
    let duration: TimeInterval
    let offset: TimeInterval
    let label: String
    private let target: Entity
    private let frames: [Keyframe<Value>]
    private let read: (Entity) -> Value
    private let write: (Entity, Value) -> Void

    private var startValue: Value?

    init(
        target: Entity, offset: TimeInterval, label: String, frames: [Keyframe<Value>],
        read: @escaping (Entity) -> Value, write: @escaping (Entity, Value) -> Void
    ) {
        self.target = target
        self.offset = max(offset, 0)
        self.label = label
        self.frames = frames.sorted { $0.time < $1.time }
        self.duration = frames.map(\.time).max() ?? 0
        self.read = read
        self.write = write
    }

    func begin(in scene: Scene) {
        guard startValue == nil else { return }
        startValue = read(target)
    }

    func apply(at clipTime: TimeInterval, in scene: Scene) {
        guard let start = startValue, !frames.isEmpty else { return }
        let local = min(max(clipTime - offset, 0), duration)

        var previousTime: TimeInterval = 0
        var previousValue = start
        for frame in frames {
            if local <= frame.time {
                let span = frame.time - previousTime
                let t = span <= 0 ? 1 : (local - previousTime) / span
                write(target, Value.lerp(previousValue, frame.value, frame.easing.apply(t)))
                return
            }
            previousTime = frame.time
            previousValue = frame.value
        }
        write(target, frames[frames.count - 1].value)
    }

    func rewind(in scene: Scene) {
        if let start = startValue {
            write(target, start)
        }
    }
}

// MARK: - Structural tracks

/// 0-duration track that adds entities (and on rewind, removes them again).
@MainActor
final class AddEntitiesTrack: AnimationTrackProtocol {
    let duration: TimeInterval = 0
    let offset: TimeInterval = 0
    let label: String

    private let entities: [Entity]
    /// Entities this track actually inserted (so rewind doesn't evict pre-existing ones).
    private var inserted: [Entity]?

    init(entities: [Entity]) {
        self.entities = entities
        self.label = "add(" + entities.map { name(of: $0) }.joined(separator: ", ") + ")"
    }

    /// The entities this track was built to introduce — known at build time (the
    /// `inserted` subset is only computed at runtime `begin`). `Story` scans these
    /// across a slide's clips to find what to tear down at the slide's end.
    var introducedTargets: [Entity] { entities }

    func begin(in scene: Scene) {
        guard inserted == nil else { return }
        inserted = entities.filter { $0.scene !== scene }
    }

    func apply(at clipTime: TimeInterval, in scene: Scene) {
        for entity in inserted ?? [] {
            scene.insert(entity)
        }
    }

    func rewind(in scene: Scene) {
        for entity in inserted ?? [] {
            scene.detach(entity)
        }
    }
}

/// 0-duration track at `offset` (an erase animation's end) that removes its
/// entity from the scene. Scrubbing back re-inserts at the original root index
/// so painter's order and debug-label paths survive the round trip.
@MainActor
final class RemoveEntityTrack: AnimationTrackProtocol {
    let duration: TimeInterval = 0
    let offset: TimeInterval
    let label: String

    private let entity: Entity
    private var hasBegun = false
    /// Root index at clip start; nil = not a scene root then (nothing to remove).
    private var rootIndex: Int?

    init(entity: Entity, at offset: TimeInterval) {
        self.entity = entity
        self.offset = max(offset, 0)
        self.label = "remove(\(name(of: entity)))"
    }

    /// The entity this track removes — `Story` reads it to exclude net-transient
    /// entities (a `.fade` overlay, a `.highlight` border introduced *and* removed
    /// inside one slide) from the slide's carry-forward set.
    var removedTarget: Entity { entity }

    func begin(in scene: Scene) {
        guard !hasBegun else { return }
        hasBegun = true
        rootIndex = scene.entities.firstIndex { $0 === entity }
    }

    func apply(at clipTime: TimeInterval, in scene: Scene) {
        // Targets introduced by this same clip (highlight borders) aren't
        // roots yet at begin — resolve once the AddEntitiesTrack ran.
        if rootIndex == nil {
            rootIndex = scene.entities.firstIndex { $0 === entity }
        }
        guard let index = rootIndex else { return }
        if clipTime >= offset {
            scene.detach(entity)
        } else {
            scene.insert(entity, at: index)
        }
    }

    func rewind(in scene: Scene) {
        guard let index = rootIndex else { return }
        scene.insert(entity, at: index)
    }
}

/// Near-zero-duration track that clears every scene root except a protected set
/// (the story's globals). What it removes is captured at `begin` (runtime), so
/// it is accurate at the timeline point it actually plays, and scrubbing back
/// re-inserts each at its original depth (ascending, so the indices rebuild the
/// original order). Powers `Scene.clear()`.
///
/// The sentinel duration (1e-7) is below the step-boundary collapse threshold
/// (1e-6), so it introduces no extra step. The `> 0` apply condition means
/// seeking *to* the clear's start time (landing on the slide boundary) does
/// not fire the clear — only advancing *past* it (right arrow / scroll) does.
/// This keeps the previous slide's content visible until the viewer explicitly
/// moves forward.
@MainActor
final class ClearAllTrack: AnimationTrackProtocol {
    /// Sentinel: small enough to collapse into the surrounding step boundary
    /// (< 1e-6), large enough that `apply(at: duration)` satisfies `> 0`.
    let duration: TimeInterval = 1e-7
    let offset: TimeInterval = 0
    let label = "clear()"

    private let protectedIDs: Set<ObjectIdentifier>
    private var captured = false
    private var removals: [(entity: Entity, index: Int)] = []

    init(protectedIDs: Set<ObjectIdentifier>) {
        self.protectedIDs = protectedIDs
    }

    func begin(in scene: Scene) {
        guard !captured else { return }
        captured = true
        removals = scene.entities.enumerated()
            .filter { !protectedIDs.contains(ObjectIdentifier($0.element)) }
            .map { (entity: $0.element, index: $0.offset) }
    }

    func apply(at clipTime: TimeInterval, in scene: Scene) {
        if clipTime > 0 {
            for removal in removals { scene.detach(removal.entity) }
        } else {
            for removal in removals { scene.insert(removal.entity, at: removal.index) }
        }
    }

    func rewind(in scene: Scene) {
        for removal in removals { scene.insert(removal.entity, at: removal.index) }
    }
}

/// Suspends one system type for the active window of the clip.
@MainActor
final class PauseSystemTrack: AnimationTrackProtocol {
    let duration: TimeInterval
    let offset: TimeInterval = 0
    let label: String

    private let systemID: ObjectIdentifier

    init(systemID: ObjectIdentifier, systemName: String, duration: TimeInterval) {
        self.systemID = systemID
        self.duration = max(duration, 0)
        self.label = "pause(\(systemName))"
    }

    func begin(in scene: Scene) {}

    func apply(at clipTime: TimeInterval, in scene: Scene) {
        scene.systems.setSuspended(clipTime < duration, typeID: systemID)
    }

    func rewind(in scene: Scene) {
        scene.systems.setSuspended(false, typeID: systemID)
    }
}

/// Empty clip body for `scene.wait(...)` — time passes, systems keep running.
@MainActor
final class WaitTrack: AnimationTrackProtocol {
    let duration: TimeInterval
    let offset: TimeInterval = 0
    let label: String

    init(duration: TimeInterval) {
        self.duration = max(duration, 0)
        self.label = "wait(\(fmt(duration, decimals: 2))s)"
    }

    func begin(in scene: Scene) {}
    func apply(at clipTime: TimeInterval, in scene: Scene) {}
    func rewind(in scene: Scene) {}
}
