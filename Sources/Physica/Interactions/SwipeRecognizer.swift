// SwipeRecognizer — turns a press → move… → release gesture into a single swipe
// direction. Distance/dominant-axis based on purpose: no clock (so it stays
// deterministic and Foundation-free, host-testable by feeding world points), and
// a velocity model would only fight the browser, which already consumes fast
// vertical drags as page scroll. The story shell feeds it touch points and maps
// a horizontal swipe to step navigation.

/// The four cardinal directions a completed swipe can resolve to.
import PhysicaFoundation
import PhysicaTypesetting

package enum SwipeDirection: Sendable, Equatable {
    case left, right, up, down
}

/// Accumulates a gesture's net displacement and, at `end()`, reports the dominant
/// cardinal direction when it travelled at least `threshold` along that axis.
/// World-unit thresholds, so a swipe reads the same regardless of canvas pixels.
package struct SwipeRecognizer: Sendable {
    /// Minimum net displacement (world units) along the dominant axis for the
    /// gesture to count as a swipe. Below this, `end()` is `nil` (a tap or a nudge).
    package var threshold: Real

    private var start: Position?
    private var latest: Position = .zero

    package init(threshold: Real = 1.0) {
        self.threshold = threshold
    }

    /// True between `begin()` and the next `end()`/`cancel()`.
    package var isTracking: Bool { start != nil }

    package mutating func begin(at point: Position) {
        start = point
        latest = point
    }

    package mutating func move(to point: Position) {
        guard start != nil else { return }
        latest = point
    }

    /// Resolves and clears the gesture: the dominant axis wins, and only if its
    /// net displacement reaches `threshold`. A diagonal resolves to whichever
    /// axis moved farther; a tie or a sub-threshold drag returns `nil`.
    package mutating func end() -> SwipeDirection? {
        guard let start else { return nil }
        let delta = latest - start
        self.start = nil
        let dx = delta.x
        let dy = delta.y
        if Swift.abs(dx) >= Swift.abs(dy) {
            guard Swift.abs(dx) >= threshold else { return nil }
            return dx < 0 ? .left : .right
        } else {
            guard Swift.abs(dy) >= threshold else { return nil }
            // World y points up, so a downward swipe is decreasing y.
            return dy < 0 ? .down : .up
        }
    }

    /// Aborts the gesture without resolving (pointer cancelled, gesture stolen).
    package mutating func cancel() {
        start = nil
    }
}
