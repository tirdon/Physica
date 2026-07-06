// DecimalTracking — fixed-decimal counter display ("3.14"), formatted with the
// framework's hand-rolled `fmt` so Float and Double hosts print identically.

import PhysicaFoundation

public struct DecimalTracking: ValueTracking {
    public let decimals: Int

    public init(decimals: Int = 2) {
        self.decimals = decimals
    }

    public func text(for value: Real) -> String {
        fmt(value, decimals: decimals)
    }
}
