// Value tracks — interpolate a property over clip-local time: PropertyTrack
// (any Interpolatable), SpinTrack (exact multi-turn rotation), and KeyframeTrack
// (multi-stop). See Tracks.swift for the AnimationTrackProtocol contract.

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
