// Easing curves applied to normalized track time (0...1 in, ~0...1 out).

public enum Easing: Sendable {
    case linear
    case easeIn
    case easeOut
    case easeInOut
    /// Manim-style smoothstep (3t² − 2t³).
    case smooth
    /// Smootherstep (6t⁵ − 15t⁴ + 10t³).
    case doubleSmooth
    case sigmoid(steepness: Real)
    case expoIn
    case expoOut
    case elasticIn
    case elasticOut
    case bounce
    /// Oscillates `oscillations` times, returning to 0.
    case wiggle(oscillations: Int)
    /// Underdamped spring settling at 1.
    case spring(damping: Real, stiffness: Real)
    case custom(@Sendable (Real) -> Real)

    public func apply(_ t: Real) -> Real {
        let t = min(max(t, 0), 1)
        switch self {
        case .linear:
            return t
        case .easeIn:
            return t * t
        case .easeOut:
            return t * (2 - t)
        case .easeInOut:
            return t < 0.5 ? 2 * t * t : 1 - Real.pow(-2 * t + 2, 2) / 2
        case .smooth:
            return t * t * (3 - 2 * t)
        case .doubleSmooth:
            return t * t * t * (t * (6 * t - 15) + 10)
        case .sigmoid(let steepness):
            let raw = 1 / (1 + Real.exp(-steepness * (t - 0.5)))
            let low = 1 / (1 + Real.exp(steepness / 2))
            let high = 1 / (1 + Real.exp(-steepness / 2))
            return (raw - low) / (high - low)
        case .expoIn:
            return t == 0 ? 0 : Real.pow(2, 10 * t - 10)
        case .expoOut:
            return t == 1 ? 1 : 1 - Real.pow(2, -10 * t)
        case .elasticIn:
            if t == 0 || t == 1 { return t }
            let c = (2 * Real.pi) / 3
            return -Real.pow(2, 10 * t - 10) * Real.sin((t * 10 - 10.75) * c)
        case .elasticOut:
            if t == 0 || t == 1 { return t }
            let c = (2 * Real.pi) / 3
            return Real.pow(2, -10 * t) * Real.sin((t * 10 - 0.75) * c) + 1
        case .bounce:
            let n: Real = 7.5625
            let d: Real = 2.75
            var t = t
            if t < 1 / d {
                return n * t * t
            } else if t < 2 / d {
                t -= 1.5 / d
                return n * t * t + 0.75
            } else if t < 2.5 / d {
                t -= 2.25 / d
                return n * t * t + 0.9375
            } else {
                t -= 2.625 / d
                return n * t * t + 0.984375
            }
        case .wiggle(let oscillations):
            return Real.sin(Real(oscillations) * Real.pi * t) * (1 - t)
        case .spring(let damping, let stiffness):
            if t == 0 || t == 1 { return t }
            let omega = stiffness.squareRoot()
            let zeta = min(damping / (2 * omega), 0.999)
            let omegaD = omega * (1 - zeta * zeta).squareRoot()
            let decay = Real.exp(-zeta * omega * t)
            return 1 - decay * (Real.cos(omegaD * t) + (zeta * omega / omegaD) * Real.sin(omegaD * t))
        case .custom(let curve):
            return curve(t)
        }
    }
}
