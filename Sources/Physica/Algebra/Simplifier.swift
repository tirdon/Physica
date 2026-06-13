// Canonical-form simplifier — the equality engine behind target matching and
// every game move. Applies the core algebraic properties the way the Equalynx
// engine does (commutative → deterministic operand order, associative → n-ary
// flatten, exact constant folding through Rational, like-term collection,
// additive/multiplicative/power identities) and rebuilds a deterministic
// display tree. Distribution is deliberately NOT applied here — `c(a+b)` keeps
// its shape; Expression.matches compares distributed forms separately.

struct Simplifier {

    func simplify(_ expression: Expression) throws -> Expression {
        try Simplifier.rebuild(try additiveTerms(of: expression))
    }

    // MARK: - Canonical representation

    /// One multiplicative atom of a term: base^exponent, integer exponents only
    /// (symbolic exponents stay inside an opaque `.power` base).
    struct CanonicalFactor {
        var base: Expression
        var exponent: Int
    }

    /// One additive term: coefficient × ∏ factors, factors sorted by base key.
    struct CanonicalTerm {
        var coefficient: Rational
        var factors: [CanonicalFactor]

        /// Like-term grouping key — everything but the coefficient.
        var groupKey: String {
            var parts: [String] = []
            for factor in factors {
                parts.append(factor.base.orderKey + "^\(factor.exponent)")
            }
            return parts.joined(separator: "|")
        }
    }

    // MARK: - Sum normalization

    /// Flatten, recurse, fold, collect, sort. Always returns combined terms.
    func additiveTerms(of expression: Expression) throws -> [CanonicalTerm] {
        try combine(try rawTerms(of: expression))
    }

    private func rawTerms(of expression: Expression) throws -> [CanonicalTerm] {
        switch expression {
        case .number(let value):
            return value.isZero ? [] : [CanonicalTerm(coefficient: value, factors: [])]
        case .variable, .constant, .vector:
            return [CanonicalTerm(coefficient: .one, factors: [CanonicalFactor(base: expression, exponent: 1)])]
        case .function(let name, let argument):
            let base = Expression.function(name: name, argument: try simplify(argument))
            return [CanonicalTerm(coefficient: .one, factors: [CanonicalFactor(base: base, exponent: 1)])]
        case .unary(.plus, let operand):
            return try rawTerms(of: operand)
        case .unary(.minus, let operand):
            var negatedTerms: [CanonicalTerm] = []
            for term in try rawTerms(of: operand) {
                var negated = term
                negated.coefficient = try term.coefficient.negated()
                negatedTerms.append(negated)
            }
            return negatedTerms
        case .binary(.add, let lhs, let rhs):
            return try rawTerms(of: lhs) + rawTerms(of: rhs)
        case .binary(.subtract, let lhs, let rhs):
            return try rawTerms(of: lhs) + rawTerms(of: .unary(.minus, rhs))
        case .binary(.multiply, _, _), .binary(.implicitMultiply, _, _), .binary(.divide, _, _):
            return [try productTerm(of: expression)]
        case .binary(.power, let base, let exponent):
            return try powerTerms(base: base, exponent: exponent)
        }
    }

    private func combine(_ terms: [CanonicalTerm]) throws -> [CanonicalTerm] {
        var result: [CanonicalTerm] = []
        for term in terms where !term.coefficient.isZero {
            if let existing = result.firstIndex(where: { $0.groupKey == term.groupKey }) {
                result[existing].coefficient = try result[existing].coefficient + term.coefficient
            } else {
                result.append(term)
            }
        }
        result.removeAll { $0.coefficient.isZero }
        // Display order: symbol-bearing terms by key, the pure number last
        // ("2x + 3", "-2x + 5" — '~' sorts after every ASCII printable).
        result.sort { lhs, rhs in
            let leftKey = lhs.factors.isEmpty ? "~" : lhs.groupKey
            let rightKey = rhs.factors.isEmpty ? "~" : rhs.groupKey
            return leftKey < rightKey
        }
        return result
    }

    // MARK: - Product normalization

    private func productTerm(of expression: Expression) throws -> CanonicalTerm {
        var coefficient = Rational.one
        var factors: [CanonicalFactor] = []
        var isZero = false
        try collectProduct(expression, exponentSign: 1, into: &coefficient, &factors, &isZero)
        if isZero {
            return CanonicalTerm(coefficient: .zero, factors: [])
        }
        // Merge like bases (x·x → x², sin θ · sin θ → sin²θ) and sort.
        var merged: [CanonicalFactor] = []
        for factor in factors {
            if let existing = merged.firstIndex(where: { $0.base.orderKey == factor.base.orderKey }) {
                merged[existing].exponent += factor.exponent
            } else {
                merged.append(factor)
            }
        }
        merged.removeAll { $0.exponent == 0 }
        merged.sort { $0.base.orderKey < $1.base.orderKey }
        return CanonicalTerm(coefficient: coefficient, factors: merged)
    }

    private func collectProduct(
        _ expression: Expression,
        exponentSign: Int,
        into coefficient: inout Rational,
        _ factors: inout [CanonicalFactor],
        _ isZero: inout Bool
    ) throws {
        switch expression {
        case .binary(.multiply, let lhs, let rhs), .binary(.implicitMultiply, let lhs, let rhs):
            try collectProduct(lhs, exponentSign: exponentSign, into: &coefficient, &factors, &isZero)
            try collectProduct(rhs, exponentSign: exponentSign, into: &coefficient, &factors, &isZero)
        case .binary(.divide, let lhs, let rhs):
            try collectProduct(lhs, exponentSign: exponentSign, into: &coefficient, &factors, &isZero)
            try collectProduct(rhs, exponentSign: -exponentSign, into: &coefficient, &factors, &isZero)
        case .unary(.plus, let operand):
            try collectProduct(operand, exponentSign: exponentSign, into: &coefficient, &factors, &isZero)
        case .unary(.minus, let operand):
            coefficient = try coefficient.negated()
            try collectProduct(operand, exponentSign: exponentSign, into: &coefficient, &factors, &isZero)
        case .number(let value):
            if value.isZero {
                if exponentSign > 0 {
                    isZero = true
                } else {
                    throw AlgebraError.divisionByZero
                }
            } else {
                coefficient = exponentSign > 0
                    ? try coefficient * value
                    : try coefficient / value
            }
        case .binary(.power, let base, let exponent):
            try collectPower(
                base: base, exponent: exponent, exponentSign: exponentSign,
                into: &coefficient, &factors, &isZero
            )
        case .binary(.add, _, _), .binary(.subtract, _, _):
            let inner = try simplify(expression)
            switch inner {
            case .binary(.add, _, _), .binary(.subtract, _, _), .unary(.minus, _):
                // Still a sum after simplification → one opaque factor;
                // no auto-distribution.
                factors.append(CanonicalFactor(base: inner, exponent: exponentSign))
            default:
                try collectProduct(inner, exponentSign: exponentSign, into: &coefficient, &factors, &isZero)
            }
        case .variable, .constant, .vector:
            factors.append(CanonicalFactor(base: expression, exponent: exponentSign))
        case .function(let name, let argument):
            let base = Expression.function(name: name, argument: try simplify(argument))
            factors.append(CanonicalFactor(base: base, exponent: exponentSign))
        }
    }

    private func collectPower(
        base: Expression,
        exponent: Expression,
        exponentSign: Int,
        into coefficient: inout Rational,
        _ factors: inout [CanonicalFactor],
        _ isZero: inout Bool
    ) throws {
        let foldedExponent = try simplify(exponent)
        guard case .number(let value) = foldedExponent, value.isInteger else {
            // Symbolic exponent: the whole power is one opaque factor.
            let opaque = Expression.binary(.power, try simplify(base), foldedExponent)
            factors.append(CanonicalFactor(base: opaque, exponent: exponentSign))
            return
        }
        let total = value.numerator * exponentSign
        if total == 0 { return } // x^0 → 1 contributes nothing
        let simplifiedBase = try simplify(base)
        switch simplifiedBase {
        case .number(let baseValue):
            if baseValue.isZero {
                if total > 0 { isZero = true } else { throw AlgebraError.divisionByZero }
            } else {
                coefficient = try coefficient * baseValue.raised(to: total)
            }
        case .binary(.add, _, _), .binary(.subtract, _, _), .unary(.minus, _):
            // (a+b)^n stays whole — no binomial expansion here.
            factors.append(CanonicalFactor(base: simplifiedBase, exponent: total))
        default:
            // Distribute the exponent over the base's own product:
            // (2x)^2 → 4·x². Decompose, then scale every exponent.
            let inner = try productTerm(of: simplifiedBase)
            if inner.coefficient.isZero {
                if total > 0 { isZero = true } else { throw AlgebraError.divisionByZero }
                return
            }
            coefficient = try coefficient * inner.coefficient.raised(to: total)
            for factor in inner.factors {
                factors.append(CanonicalFactor(base: factor.base, exponent: factor.exponent * total))
            }
        }
    }

    private func powerTerms(base: Expression, exponent: Expression) throws -> [CanonicalTerm] {
        let foldedExponent = try simplify(exponent)
        if case .number(let value) = foldedExponent {
            if value.isZero {
                return [CanonicalTerm(coefficient: .one, factors: [])] // x^0 → 1
            }
            if value.isOne {
                return try rawTerms(of: base) // x^1 → x
            }
        }
        return [try productTerm(of: .binary(.power, base, foldedExponent))]
    }

    // MARK: - Rebuild (canonical display tree)

    static func rebuild(_ terms: [CanonicalTerm]) throws -> Expression {
        guard !terms.isEmpty else { return .number(.zero) }

        // Single pure-number term keeps its sign in the literal.
        if terms.count == 1, terms[0].factors.isEmpty {
            return .number(terms[0].coefficient)
        }

        var result: Expression?
        for term in terms {
            let negative = term.coefficient.isNegative
            let magnitude = negative ? try term.coefficient.negated() : term.coefficient
            let body = try termExpression(magnitude: magnitude, factors: term.factors)
            if let accumulated = result {
                result = .binary(negative ? .subtract : .add, accumulated, body)
            } else {
                result = negative ? .unary(.minus, body) : body
            }
        }
        return result ?? .number(.zero)
    }

    /// |coefficient| × factors → numerator/denominator display split.
    private static func termExpression(magnitude: Rational, factors: [CanonicalFactor]) throws -> Expression {
        var numeratorParts: [Expression] = []
        var denominatorParts: [Expression] = []

        if magnitude.numerator != 1 {
            numeratorParts.append(.number(Rational(magnitude.numerator)))
        }
        if magnitude.denominator != 1 {
            denominatorParts.append(.number(Rational(magnitude.denominator)))
        }
        for factor in factors {
            let body = factor.exponent.magnitude == 1
                ? factor.base
                : Expression.binary(.power, factor.base, .number(Rational(Int(factor.exponent.magnitude))))
            if factor.exponent > 0 {
                numeratorParts.append(body)
            } else {
                denominatorParts.append(body)
            }
        }

        let numerator = product(of: numeratorParts) ?? .number(.one)
        guard let denominator = product(of: denominatorParts) else {
            return numerator
        }
        return .binary(.divide, numerator, denominator)
    }

    private static func product(of parts: [Expression]) -> Expression? {
        guard var result = parts.first else { return nil }
        for part in parts.dropFirst() {
            result = .binary(.implicitMultiply, result, part)
        }
        return result
    }
}
