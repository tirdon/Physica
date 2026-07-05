// A single keyframe — a value to reach at a clip-local time, with the easing
// used to approach it. Consumed by KeyframeTrack (ValueTracks.swift).

import PhysicaFoundation

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
