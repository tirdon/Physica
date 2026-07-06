// UnicodeTracking — animates *through a character sequence*: the value indexes
// into `sequence` (clamped), so a counter can tick through "▁▂▃▄▅▆▇█", roll
// letters A→Z, or step any custom glyph ramp as its value rises and falls.

import PhysicaFoundation

public struct UnicodeTracking: ValueTracking {
    public let sequence: [Character]

    public init(_ sequence: [Character]) {
        self.sequence = sequence
    }

    public init(_ string: String) {
        self.sequence = Array(string)
    }

    public func text(for value: Real) -> String {
        guard !sequence.isEmpty else { return "" }
        let index = Swift.min(Swift.max(Int(value.rounded()), 0), sequence.count - 1)
        return String(sequence[index])
    }
}
