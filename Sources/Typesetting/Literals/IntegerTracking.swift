// ValueTracking + IntegerTracking — the formatter side of animated counters.
// A tracking turns the counter's continuously-animated `Real` value into the
// display string a `TrackingTextEntity` reglyphs each frame; the protocol is
// pure and host-safe, so trackings unit-test without fonts or scenes.

import PhysicaFoundation

/// Formats a continuously-animated value as display text.
public protocol ValueTracking: Sendable {
    func text(for value: Real) -> String
}

/// Whole-number counter (odometer style): 0, 1, 2, … — the classic
/// "count up to N" display.
public struct IntegerTracking: ValueTracking {
    public init() {}

    public func text(for value: Real) -> String {
        "\(Int(value.rounded()))"
    }
}
