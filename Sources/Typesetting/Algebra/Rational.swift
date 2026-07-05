// Exact rational arithmetic for the algebra core. Every numeric fold in the
// simplifier and every inverse move ("divide both sides by 2") goes through
// Rational, so 3 ÷ 2 stays 3/2 — never 1.5. Fresh implementation following the
// Equalynx engine's design (github.com/tirdon/Equalynx); wasm-safe by the same
// rules as the rest of the core: no Foundation, plain `Int` interpolation only.

public enum AlgebraError: Error, Equatable, Sendable {
    case parse(String)
    case overflow
    case divisionByZero
    case unsupported(String)

    /// Human-facing reason, used by rejected game moves.
    public var message: String {
        switch self {
        case .parse(let detail): return detail
        case .overflow: return "That number grew too large."
        case .divisionByZero: return "Cannot divide by zero."
        case .unsupported(let detail): return detail
        }
    }
}

/// An exact fraction, gcd-normalized at init, denominator always positive.
public struct Rational: Sendable, Equatable, Hashable {
    public let numerator: Int
    public let denominator: Int

    /// Whole number — never throws, never needs reduction.
    public init(_ value: Int) {
        numerator = value
        denominator = 1
    }

    /// General fraction. Throws `.divisionByZero` for a zero denominator and
    /// `.overflow` when normalization itself cannot be represented.
    public init(_ numerator: Int, over denominator: Int) throws {
        guard denominator != 0 else { throw AlgebraError.divisionByZero }
        var n = numerator
        var d = denominator
        if d < 0 {
            guard n != Int.min, d != Int.min else { throw AlgebraError.overflow }
            n = -n
            d = -d
        }
        let magnitude = Rational.gcd(n.magnitude, d.magnitude)
        guard magnitude <= UInt(Int.max) else { throw AlgebraError.overflow }
        let g = Int(magnitude)
        self.numerator = n / g
        self.denominator = d / g
    }

    /// Decimal literal: digits with one optional point ("3", "0.5" → 1/2).
    /// The scale stays exact — "3.50" parses to 7/2.
    public init(decimalText: String) throws {
        var whole = 0
        var fraction = 0
        var scale = 1
        var seenPoint = false
        var seenDigit = false
        for byte in Array(decimalText.utf8) {
            if byte == 46 { // '.'
                guard !seenPoint else { throw AlgebraError.parse("Malformed number '\(decimalText)'.") }
                seenPoint = true
                continue
            }
            guard byte >= 48, byte <= 57 else {
                throw AlgebraError.parse("Malformed number '\(decimalText)'.")
            }
            seenDigit = true
            let digit = Int(byte - 48)
            if seenPoint {
                let (s, so) = scale.multipliedReportingOverflow(by: 10)
                let (f, fo) = fraction.multipliedReportingOverflow(by: 10)
                guard !so, !fo else { throw AlgebraError.overflow }
                let (f2, ao) = f.addingReportingOverflow(digit)
                guard !ao else { throw AlgebraError.overflow }
                scale = s
                fraction = f2
            } else {
                let (w, wo) = whole.multipliedReportingOverflow(by: 10)
                guard !wo else { throw AlgebraError.overflow }
                let (w2, ao) = w.addingReportingOverflow(digit)
                guard !ao else { throw AlgebraError.overflow }
                whole = w2
            }
        }
        guard seenDigit else { throw AlgebraError.parse("Malformed number '\(decimalText)'.") }
        let (scaled, so) = whole.multipliedReportingOverflow(by: scale)
        guard !so else { throw AlgebraError.overflow }
        let (n, ao) = scaled.addingReportingOverflow(fraction)
        guard !ao else { throw AlgebraError.overflow }
        try self.init(n, over: scale)
    }

    public static let zero = Rational(0)
    public static let one = Rational(1)

    public var isZero: Bool { numerator == 0 }
    public var isOne: Bool { numerator == 1 && denominator == 1 }
    public var isNegative: Bool { numerator < 0 }
    public var isInteger: Bool { denominator == 1 }

    /// "3", "-3", "3/2" — display layers turn fractions into \frac themselves.
    public var displayText: String {
        denominator == 1 ? "\(numerator)" : "\(numerator)/\(denominator)"
    }

    // MARK: - Arithmetic (all exact, all overflow-checked)

    public static func + (lhs: Rational, rhs: Rational) throws -> Rational {
        let (a, ao) = lhs.numerator.multipliedReportingOverflow(by: rhs.denominator)
        let (b, bo) = rhs.numerator.multipliedReportingOverflow(by: lhs.denominator)
        let (d, dOverflow) = lhs.denominator.multipliedReportingOverflow(by: rhs.denominator)
        guard !ao, !bo, !dOverflow else { throw AlgebraError.overflow }
        let (n, no) = a.addingReportingOverflow(b)
        guard !no else { throw AlgebraError.overflow }
        return try Rational(n, over: d)
    }

    public static func - (lhs: Rational, rhs: Rational) throws -> Rational {
        try lhs + rhs.negated()
    }

    public static func * (lhs: Rational, rhs: Rational) throws -> Rational {
        let (n, no) = lhs.numerator.multipliedReportingOverflow(by: rhs.numerator)
        let (d, dOverflow) = lhs.denominator.multipliedReportingOverflow(by: rhs.denominator)
        guard !no, !dOverflow else { throw AlgebraError.overflow }
        return try Rational(n, over: d)
    }

    public static func / (lhs: Rational, rhs: Rational) throws -> Rational {
        guard !rhs.isZero else { throw AlgebraError.divisionByZero }
        return try lhs * rhs.reciprocal()
    }

    public func negated() throws -> Rational {
        guard numerator != Int.min else { throw AlgebraError.overflow }
        return try Rational(-numerator, over: denominator)
    }

    public func reciprocal() throws -> Rational {
        guard !isZero else { throw AlgebraError.divisionByZero }
        return try Rational(denominator, over: numerator)
    }

    /// Integer power. 0^0 folds to 1 (the usual CAS convention); a negative
    /// exponent of zero throws `.divisionByZero`.
    public func raised(to exponent: Int) throws -> Rational {
        if exponent == 0 { return .one }
        if isZero {
            guard exponent > 0 else { throw AlgebraError.divisionByZero }
            return .zero
        }
        let base = exponent > 0 ? self : try reciprocal()
        var result = Rational.one
        var remaining = exponent.magnitude
        while remaining > 0 {
            result = try result * base
            remaining -= 1
        }
        return result
    }

    static func gcd(_ a: UInt, _ b: UInt) -> UInt {
        var x = a
        var y = b
        while y != 0 {
            (x, y) = (y, x % y)
        }
        return x == 0 ? 1 : x
    }
}
