// Reading-order token list for an equation — the Equalynx pattern: each token
// renders to its OWN glyph run (one MathJax call per token on the web), so
// every token is independently draggable and its semantics are intrinsic.
// One token per top-level factor: a fraction is ONE \frac token, a function
// with its argument is ONE token, a parenthesized sum is ONE token. Implicit
// multiplication emits no operator token — the right factor glues instead.

public struct DisplayToken: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case number, op, equals, variable, constant, function, vector
    }

    public var kind: Kind
    /// Human-facing symbol ("3", "+", "θ", "cos θ") — host font rendering and
    /// debug output.
    public var value: String
    /// TeX source for this one token ("\\frac{3}{2}", "\\cos\\theta").
    public var tex: String
    /// Hug the previous token (juxtaposed factor — the x in 2x).
    public var glue: Bool
    /// Move address; nil for operators and '='.
    public var address: TokenAddress?

    public init(kind: Kind, value: String, tex: String, glue: Bool = false, address: TokenAddress? = nil) {
        self.kind = kind
        self.value = value
        self.tex = tex
        self.glue = glue
        self.address = address
    }
}

public extension Equation {
    /// Reading order: lhs terms, '=', rhs terms. Addresses round-trip through
    /// `term(at:)` because both walk the same display tree.
    func buildTokens() -> [DisplayToken] {
        var tokens: [DisplayToken] = []
        appendSide(lhs, as: .lhs, into: &tokens)
        tokens.append(DisplayToken(kind: .equals, value: "=", tex: "="))
        appendSide(rhs, as: .rhs, into: &tokens)
        return tokens
    }

    private func appendSide(_ expression: Expression, as side: EquationSide, into tokens: inout [DisplayToken]) {
        let terms = expression.displayTerms
        guard !terms.isEmpty else {
            tokens.append(DisplayToken(
                kind: .number, value: "0", tex: "0",
                address: TokenAddress(side: side, termIndex: 0)
            ))
            return
        }
        for (index, item) in terms.enumerated() {
            if index > 0 || item.negative {
                tokens.append(DisplayToken(
                    kind: .op,
                    value: item.negative ? "\u{2212}" : "+",
                    tex: item.negative ? "-" : "+"
                ))
            }
            appendTerm(item.term, side: side, termIndex: index, into: &tokens)
        }
    }

    private func appendTerm(_ term: Expression, side: EquationSide, termIndex: Int, into tokens: inout [DisplayToken]) {
        let factors = term.displayFactors
        let isProduct = factors.count > 1
        for (index, factor) in factors.enumerated() {
            // A sum standing as one factor token carries its own parens —
            // the token renders alone, so the product context can't add them.
            let texSource: String
            switch factor {
            case .binary(.add, _, _), .binary(.subtract, _, _), .unary:
                texSource = "\\left(" + factor.tex + "\\right)"
            default:
                texSource = factor.tex
            }
            tokens.append(DisplayToken(
                kind: DisplayToken.kind(of: factor),
                value: DisplayToken.plainText(of: factor),
                tex: texSource,
                glue: index > 0,
                address: TokenAddress(
                    side: side,
                    termIndex: termIndex,
                    factorIndex: isProduct ? index : nil
                )
            ))
        }
    }
}

extension DisplayToken {
    /// Dominant kind of a one-token factor (styling/affordance only — moves go
    /// by address).
    static func kind(of expression: Expression) -> Kind {
        switch expression {
        case .number: return .number
        case .variable: return .variable
        case .constant: return .constant
        case .vector: return .vector
        case .function: return .function
        case .unary(_, let operand): return kind(of: operand)
        case .binary(.power, let base, _): return kind(of: base)
        case .binary(.divide, let lhs, let rhs):
            let left = kind(of: lhs)
            return left == .number && kind(of: rhs) == .number ? .number : left
        case .binary: return expression.containsVector ? .vector : .variable
        }
    }

    /// Plain-text mirror of `tex` ("3/2", "cos θ", "(a + b)").
    static func plainText(of expression: Expression) -> String {
        switch expression {
        case .number(let value):
            return value.displayText
        case .variable(let name), .constant(let name):
            return Expression.displayName(name)
        case .vector(let name):
            return Expression.displayName(name)
        case .unary(let op, let operand):
            return (op == .minus ? "\u{2212}" : "+") + plainText(of: operand)
        case .function(let name, let argument):
            switch argument {
            case .number, .variable, .constant, .vector:
                return name + " " + plainText(of: argument)
            default:
                return name + "(" + plainText(of: argument) + ")"
            }
        case .binary(.add, let lhs, let rhs):
            return "(" + plainText(of: lhs) + " + " + plainText(of: rhs) + ")"
        case .binary(.subtract, let lhs, let rhs):
            return "(" + plainText(of: lhs) + " \u{2212} " + plainText(of: rhs) + ")"
        case .binary(.multiply, let lhs, let rhs), .binary(.implicitMultiply, let lhs, let rhs):
            return plainText(of: lhs) + plainText(of: rhs)
        case .binary(.divide, let lhs, let rhs):
            return plainText(of: lhs) + "/" + plainText(of: rhs)
        case .binary(.power, let lhs, let rhs):
            return plainText(of: lhs) + "^" + plainText(of: rhs)
        }
    }
}
