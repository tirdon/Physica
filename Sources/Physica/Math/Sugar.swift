// Numeric sugar for the scripted API: `1.i + 2.j`, `scene.wait(2.s)`, `.origin`.

public extension BinaryInteger {
    /// Unit vector along +x scaled by self: `3.i == Position(3, 0, 0)`.
    var i: Position { Position(Real(self), 0, 0) }
    /// Unit vector along +y scaled by self.
    var j: Position { Position(0, Real(self), 0) }
    /// Unit vector along +z scaled by self.
    var k: Position { Position(0, 0, Real(self)) }
    /// Seconds as a `Duration`: `2.s`.
    var s: Duration { .seconds(Int64(self)) }
}

public extension BinaryFloatingPoint {
    var i: Position { Position(Real(self), 0, 0) }
    var j: Position { Position(0, Real(self), 0) }
    var k: Position { Position(0, 0, Real(self)) }
    var s: Duration { .seconds(Double(self)) }
}

public extension SIMD3 where Scalar == Real {
    static var origin: Position { .zero }
    static var iAxis: Position { Position(1, 0, 0) }
    static var jAxis: Position { Position(0, 1, 0) }
    static var kAxis: Position { Position(0, 0, 1) }

    var length: Real { (x * x + y * y + z * z).squareRoot() }
    var lengthSquared: Real { x * x + y * y + z * z }

    var normalized: Position {
        let l = length
        return l > Real.ulpOfOne ? self / l : .zero
    }

    func distance(to other: Position) -> Real { (self - other).length }

    func dot(_ other: Position) -> Real {
        x * other.x + y * other.y + z * other.z
    }

    func cross(_ other: Position) -> Position {
        Position(
            y * other.z - z * other.y,
            z * other.x - x * other.z,
            x * other.y - y * other.x
        )
    }

    /// Component-wise linear interpolation.
    static func lerp(_ a: Position, _ b: Position, _ t: Real) -> Position {
        a + (b - a) * t
    }
}

public extension Duration {
    /// Seconds as the framework's scalar.
    var interval: TimeInterval {
        let parts = components
        return TimeInterval(parts.seconds) + TimeInterval(Double(parts.attoseconds) * 1e-18)
    }

    static func interval(_ seconds: TimeInterval) -> Duration {
        .seconds(Double(seconds))
    }
}
