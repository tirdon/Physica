// Equation = lhs = rhs, plus the game moves. The core rule (Equalynx design):
// dragging a token across the `=` applies its INVERSE to both sides — an
// addend subtracts from both, a coefficient divides both (exact rationals).
// Dropping an external expression onto a side applies it to BOTH sides; an
// ambiguous multiplier-onto-sum surfaces as a `.choice` (factored/distributed)
// for the UI's choice chips.

public struct Equation: Sendable, Equatable, Hashable {
    public var lhs: Expression
    public var rhs: Expression

    public init(lhs: Expression, rhs: Expression) {
        self.lhs = lhs
        self.rhs = rhs
    }

    /// Split on the first top-level '=' (outside any parens/braces), parse
    /// each side. Throws when '=' is missing or a side is empty.
    public init(parsing source: String) throws {
        let bytes = Array(source.utf8)
        var depth = 0
        var split = -1
        var i = 0
        while i < bytes.count {
            switch bytes[i] {
            case 40, 123: depth += 1 // ( {
            case 41, 125: depth -= 1 // ) }
            case 61 where depth == 0: // '='
                split = i
                i = bytes.count
                continue
            default: break
            }
            i += 1
        }
        guard split >= 0 else {
            throw AlgebraError.parse("An equation needs '='.")
        }
        let left = String(decoding: bytes[0..<split], as: UTF8.self)
        let right = String(decoding: bytes[(split + 1)...], as: UTF8.self)
        lhs = try Expression(parsing: left)
        rhs = try Expression(parsing: right)
    }

    public func simplified() throws -> Equation {
        Equation(lhs: try lhs.simplified(), rhs: try rhs.simplified())
    }

    /// Algebraic equality; also accepts the sides swapped.
    public func matches(_ other: Equation) -> Bool {
        (lhs.matches(other.lhs) && rhs.matches(other.rhs))
            || (lhs.matches(other.rhs) && rhs.matches(other.lhs))
    }

    public var tex: String {
        lhs.tex + " = " + rhs.tex
    }

    public func side(_ which: EquationSide) -> Expression {
        which == .lhs ? lhs : rhs
    }
}

// MARK: - Addresses and outcomes

public enum EquationSide: Sendable, Equatable, Hashable {
    case lhs, rhs

    public var opposite: EquationSide { self == .lhs ? .rhs : .lhs }
}

public enum TermRole: Sendable, Equatable {
    case addend, factor
}

/// Where a display token lives: the n-th top-level term of a side, optionally
/// the m-th factor inside it (nil = the whole term). Produced by buildTokens,
/// consumed by the moves — both walk the same display tree, so addresses are
/// stable for a given equation value.
public struct TokenAddress: Sendable, Equatable, Hashable {
    public var side: EquationSide
    public var termIndex: Int
    public var factorIndex: Int?

    public init(side: EquationSide, termIndex: Int, factorIndex: Int? = nil) {
        self.side = side
        self.termIndex = termIndex
        self.factorIndex = factorIndex
    }
}

public struct AlgebraChoice<Value: Sendable & Equatable>: Sendable, Equatable {
    /// TeX for the preview chip.
    public var label: String
    public var value: Value

    public init(label: String, value: Value) {
        self.label = label
        self.value = value
    }
}

public enum AlgebraOutcome<Value: Sendable & Equatable>: Sendable, Equatable {
    case resolved(Value)
    case choice([AlgebraChoice<Value>])
    case rejected(reason: String)
}

public typealias MoveOutcome = AlgebraOutcome<Equation>
public typealias ExpressionOutcome = AlgebraOutcome<Expression>

// MARK: - Display flattening (shared by moves and buildTokens)

extension Expression {
    /// Top-level additive split of a display tree, signs separated.
    var displayTerms: [(negative: Bool, term: Expression)] {
        switch self {
        case .binary(.add, let lhs, let rhs):
            return lhs.displayTerms + rhs.displayTerms
        case .binary(.subtract, let lhs, let rhs):
            return lhs.displayTerms + rhs.displayTerms.map { (!$0.negative, $0.term) }
        case .unary(.minus, let operand):
            return operand.displayTerms.map { (!$0.negative, $0.term) }
        case .unary(.plus, let operand):
            return operand.displayTerms
        case .number(let value) where value.isNegative:
            // A signed literal displays as "− |n|".
            let magnitude = (try? value.negated()) ?? value
            return [(true, .number(magnitude))]
        default:
            return [(false, self)]
        }
    }

    /// Top-level multiplicative split of one term. Fractions, powers, sums and
    /// atoms are single factors; only explicit/implicit products split.
    var displayFactors: [Expression] {
        switch self {
        case .binary(.multiply, let lhs, let rhs), .binary(.implicitMultiply, let lhs, let rhs):
            return lhs.displayFactors + rhs.displayFactors
        default:
            return [self]
        }
    }
}

// MARK: - Moves

public extension Equation {
    /// The expression a display token at `address` stands for (signed for
    /// whole terms, unsigned for factors). Nil when out of range.
    func term(at address: TokenAddress) -> Expression? {
        let terms = side(address.side).displayTerms
        guard terms.indices.contains(address.termIndex) else { return nil }
        let (negative, term) = terms[address.termIndex]
        if let factorIndex = address.factorIndex {
            let factors = term.displayFactors
            guard factors.indices.contains(factorIndex) else { return nil }
            return factors[factorIndex]
        }
        return negative ? .unary(.minus, term) : term
    }

    /// Cross-'=' inverse move. Addend (or non-number factor → its whole term)
    /// subtracts from both sides; a NUMBER factor (a coefficient) divides both
    /// sides exactly. Same-side drop just folds that side (term merging).
    func movingTerm(at address: TokenAddress, to side: EquationSide) -> MoveOutcome {
        let terms = self.side(address.side).displayTerms
        guard terms.indices.contains(address.termIndex) else {
            return .rejected(reason: "No term at that position.")
        }

        if address.side == side {
            return mergingSide(side)
        }

        if let factorIndex = address.factorIndex {
            let factors = terms[address.termIndex].term.displayFactors
            guard factors.indices.contains(factorIndex) else {
                return .rejected(reason: "No factor at that position.")
            }
            let factor = factors[factorIndex]
            if case .number = factor {
                guard !factor.isZero else {
                    return .rejected(reason: AlgebraError.divisionByZero.message)
                }
                return resolving {
                    Equation(
                        lhs: try Expression.binary(.divide, lhs, factor).simplified(),
                        rhs: try Expression.binary(.divide, rhs, factor).simplified()
                    )
                }
            }
            // Symbolic factor: the whole containing term moves across
            // ("2x + 3 = 5", drag the x → "3 = -2x + 5").
        }

        let (negative, term) = terms[address.termIndex]
        let signed: Expression = negative ? .unary(.minus, term) : term
        return resolving {
            Equation(
                lhs: try Expression.binary(.subtract, lhs, signed).simplified(),
                rhs: try Expression.binary(.subtract, rhs, signed).simplified()
            )
        }
    }

    /// Same-side combine: fold the side (3 + 5 → 8, 2x + 3x → 5x). Rejected
    /// when the side is already canonical.
    private func mergingSide(_ side: EquationSide) -> MoveOutcome {
        do {
            let folded = try self.side(side).simplified()
            guard folded != self.side(side) else {
                return .rejected(reason: "Nothing to combine.")
            }
            var result = self
            if side == .lhs { result.lhs = folded } else { result.rhs = folded }
            return .resolved(result)
        } catch {
            return .rejected(reason: Equation.message(for: error))
        }
    }

    /// Drop an external expression onto a side — applied to BOTH sides so the
    /// equation stays true. A multiplier onto a sum is ambiguous: `.choice`
    /// of [factored, distributed] for the target side's display.
    func applying(_ dropped: Expression, asRole role: TermRole, to side: EquationSide) -> MoveOutcome {
        switch role {
        case .addend:
            return resolving {
                Equation(
                    lhs: try Expression.binary(.add, lhs, dropped).simplified(),
                    rhs: try Expression.binary(.add, rhs, dropped).simplified()
                )
            }
        case .factor:
            if dropped.isZero {
                return .rejected(reason: "Multiplying by zero erases the equation.")
            }
            do {
                let target = self.side(side)
                let other = self.side(side.opposite)
                let otherProduct = try Expression.binary(.implicitMultiply, dropped, other).simplified()
                let factored = try Expression.binary(.implicitMultiply, dropped, target).simplified()
                let distributed = try Simplifier().simplify(
                    Expression.distributed(.binary(.implicitMultiply, dropped, target))
                )
                if factored == distributed {
                    return .resolved(equation(target: factored, other: otherProduct, on: side))
                }
                return .choice([
                    AlgebraChoice(label: factored.tex, value: equation(target: factored, other: otherProduct, on: side)),
                    AlgebraChoice(label: distributed.tex, value: equation(target: distributed, other: otherProduct, on: side)),
                ])
            } catch {
                return .rejected(reason: Equation.message(for: error))
            }
        }
    }

    private func equation(target: Expression, other: Expression, on side: EquationSide) -> Equation {
        side == .lhs
            ? Equation(lhs: target, rhs: other)
            : Equation(lhs: other, rhs: target)
    }

    private func resolving(_ build: () throws -> Equation) -> MoveOutcome {
        do {
            return .resolved(try build())
        } catch {
            return .rejected(reason: Equation.message(for: error))
        }
    }

    private static func message(for error: Error) -> String {
        (error as? AlgebraError)?.message ?? "That move is not possible."
    }
}
