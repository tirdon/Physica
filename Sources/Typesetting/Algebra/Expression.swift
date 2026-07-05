// The algebra AST — a pure Sendable value tree, following the Equalynx
// engine's design (github.com/tirdon/Equalynx) with one extension: `.vector`
// identifiers (\vec F), which Projection.swift resolves into scalar components.
// Names are stored WITHOUT TeX escapes ("theta", "F_x"); `tex` re-adds them.

public enum UnaryOperator: Sendable, Equatable, Hashable {
    case plus, minus
}

public enum BinaryOperator: Sendable, Equatable, Hashable {
    case add, subtract, multiply, implicitMultiply, divide, power
}

public indirect enum Expression: Sendable, Equatable, Hashable {
    case number(Rational)
    case variable(String)
    case constant(String)
    /// Vector-tagged identifier: `\vec F`. Atomic to the simplifier; only
    /// projection (Projection.swift) looks inside.
    case vector(String)
    case unary(UnaryOperator, Expression)
    case binary(BinaryOperator, Expression, Expression)
    case function(name: String, argument: Expression)

    /// Parse the TeX-ish grammar the game scripts use (see ExpressionParser).
    public init(parsing source: String) throws {
        self = try ExpressionParser.parse(source)
    }

    /// Canonical display form: constants folded exactly, like terms collected,
    /// operands in deterministic order. Two expressions are algebraically
    /// identical up to commutativity/associativity iff their simplified forms
    /// are structurally equal. Distribution is never applied here.
    public func simplified() throws -> Expression {
        try Simplifier().simplify(self)
    }

    /// Algebraic equality: simplified forms compared structurally, then again
    /// after full distribution — so `c(a+b)` matches `ca + cb`. Returns false
    /// (never throws) when either side fails to fold.
    public func matches(_ other: Expression) -> Bool {
        guard let a = try? simplified(), let b = try? other.simplified() else { return false }
        if a == b { return true }
        guard
            let ea = try? Simplifier().simplify(Expression.distributed(a)),
            let eb = try? Simplifier().simplify(Expression.distributed(b))
        else { return false }
        return ea == eb
    }

    public var containsVector: Bool {
        switch self {
        case .vector: return true
        case .number, .variable, .constant: return false
        case .unary(_, let operand): return operand.containsVector
        case .binary(_, let lhs, let rhs): return lhs.containsVector || rhs.containsVector
        case .function(_, let argument): return argument.containsVector
        }
    }

    public var isZero: Bool {
        if case .number(let value) = self { return value.isZero }
        return false
    }

    // MARK: - TeX

    /// Render for MathJax (whole-expression form; per-token TeX lives in
    /// DisplayToken). Precedence-aware: products of sums get \left( \right).
    public var tex: String {
        texSource(parentBinds: 0)
    }

    /// Binding strength: 1 additive, 2 multiplicative, 3 unary, 4 power base.
    private func texSource(parentBinds: Int) -> String {
        switch self {
        case .number(let value):
            let body = value.isInteger
                ? value.displayText
                : "\\frac{\(value.numerator)}{\(value.denominator)}"
            return (value.isNegative && parentBinds >= 2) ? "\\left(\(body)\\right)" : body
        case .variable(let name), .constant(let name):
            return Expression.texName(name)
        case .vector(let name):
            return "\\vec{\(Expression.texName(name))}"
        case .unary(let op, let operand):
            let sign = op == .minus ? "-" : "+"
            let body = sign + operand.texSource(parentBinds: 3)
            return parentBinds >= 2 ? "\\left(\(body)\\right)" : body
        case .binary(let op, let lhs, let rhs):
            return binaryTex(op, lhs, rhs, parentBinds: parentBinds)
        case .function(let name, let argument):
            let arg: String
            switch argument {
            case .number, .variable, .constant, .vector:
                arg = " " + argument.texSource(parentBinds: 4)
            default:
                arg = "\\left(\(argument.texSource(parentBinds: 0))\\right)"
            }
            return "\\\(name)\(arg)"
        }
    }

    private func binaryTex(_ op: BinaryOperator, _ lhs: Expression, _ rhs: Expression, parentBinds: Int) -> String {
        switch op {
        case .add:
            let body = lhs.texSource(parentBinds: 1) + " + " + rhs.texSource(parentBinds: 1)
            return parentBinds >= 2 ? "\\left(\(body)\\right)" : body
        case .subtract:
            let body = lhs.texSource(parentBinds: 1) + " - " + rhs.texSource(parentBinds: 2)
            return parentBinds >= 2 ? "\\left(\(body)\\right)" : body
        case .multiply, .implicitMultiply:
            let left = lhs.texSource(parentBinds: 2)
            let right = rhs.texSource(parentBinds: 2)
            // Digit meeting digit needs an explicit dot (3·5, x²·2 never happen
            // post-simplify, but raw trees must stay readable).
            let separator = (lhs.endsInDigit && rhs.startsWithDigit) ? " \\cdot " : " "
            return left + separator + right
        case .divide:
            return "\\frac{\(lhs.texSource(parentBinds: 0))}{\(rhs.texSource(parentBinds: 0))}"
        case .power:
            let base: String
            switch lhs {
            case .number(let value) where value.isInteger && !value.isNegative:
                base = lhs.texSource(parentBinds: 4)
            case .variable, .constant, .vector:
                base = lhs.texSource(parentBinds: 4)
            default:
                base = "\\left(\(lhs.texSource(parentBinds: 0))\\right)"
            }
            return "\(base)^{\(rhs.texSource(parentBinds: 0))}"
        }
    }

    private var startsWithDigit: Bool {
        switch self {
        case .number(let value): return !value.isNegative
        case .binary(.multiply, let lhs, _), .binary(.implicitMultiply, let lhs, _),
             .binary(.power, let lhs, _):
            return lhs.startsWithDigit
        default: return false
        }
    }

    private var endsInDigit: Bool {
        switch self {
        case .number: return true
        case .binary(.multiply, _, let rhs), .binary(.implicitMultiply, _, let rhs):
            return rhs.endsInDigit
        default: return false
        }
    }

    /// "theta" → "\theta", "F_x" → "F_x", "F_xy" → "F_{xy}", "x" → "x".
    static func texName(_ name: String) -> String {
        let parts = splitSubscript(name)
        var base = greekNames.contains(parts.base) ? "\\" + parts.base : parts.base
        if let sub = parts.subscriptPart {
            let texSub = greekNames.contains(sub) ? "\\" + sub : sub
            base += texSub.utf8.count > 1 ? "_{\(texSub)}" : "_\(texSub)"
        }
        return base
    }

    /// Human-facing symbol for token labels and host-font rendering.
    static func displayName(_ name: String) -> String {
        let parts = splitSubscript(name)
        var base = greekSymbols[parts.base] ?? parts.base
        if let sub = parts.subscriptPart {
            base += "_" + (greekSymbols[sub] ?? sub)
        }
        return base
    }

    static func splitSubscript(_ name: String) -> (base: String, subscriptPart: String?) {
        let bytes = Array(name.utf8)
        var i = 0
        while i < bytes.count {
            if bytes[i] == 95 { // '_'
                let base = String(decoding: bytes[0..<i], as: UTF8.self)
                let sub = String(decoding: bytes[(i + 1)...], as: UTF8.self)
                return (base, sub.isEmpty ? nil : sub)
            }
            i += 1
        }
        return (name, nil)
    }

    static let greekNames: Set<String> = [
        "alpha", "beta", "gamma", "delta", "epsilon", "zeta", "eta", "theta",
        "iota", "kappa", "lambda", "mu", "nu", "xi", "pi", "rho", "sigma",
        "tau", "upsilon", "phi", "chi", "psi", "omega", "ell",
        "Gamma", "Delta", "Theta", "Lambda", "Xi", "Pi", "Sigma", "Upsilon",
        "Phi", "Psi", "Omega",
    ]

    static let greekSymbols: [String: String] = [
        "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ε",
        "zeta": "ζ", "eta": "η", "theta": "θ", "iota": "ι", "kappa": "κ",
        "lambda": "λ", "mu": "μ", "nu": "ν", "xi": "ξ", "pi": "π", "rho": "ρ",
        "sigma": "σ", "tau": "τ", "upsilon": "υ", "phi": "φ", "chi": "χ",
        "psi": "ψ", "omega": "ω", "ell": "ℓ",
        "Gamma": "Γ", "Delta": "Δ", "Theta": "Θ", "Lambda": "Λ", "Xi": "Ξ",
        "Pi": "Π", "Sigma": "Σ", "Upsilon": "Υ", "Phi": "Φ", "Psi": "Ψ",
        "Omega": "Ω",
    ]

    static let functionNames: Set<String> = ["sin", "cos", "tan", "ln", "log", "exp"]

    // MARK: - Ordering

    /// Deterministic sort key: kind rank, then name/value, then children.
    /// Drives the simplifier's commutative canonical order (`b a` → `a b`).
    var orderKey: String {
        switch self {
        case .number(let value): return "0#" + value.displayText
        case .constant(let name): return "1#" + name
        case .variable(let name): return "2#" + name
        case .vector(let name): return "3#" + name
        case .function(let name, let argument): return "4#" + name + "(" + argument.orderKey + ")"
        case .unary(let op, let operand):
            return "5#" + (op == .minus ? "-" : "+") + operand.orderKey
        case .binary(let op, let lhs, let rhs):
            return "6#" + Expression.opKey(op) + "(" + lhs.orderKey + "," + rhs.orderKey + ")"
        }
    }

    private static func opKey(_ op: BinaryOperator) -> String {
        switch op {
        case .add: return "+"
        case .subtract: return "-"
        case .multiply, .implicitMultiply: return "*"
        case .divide: return "/"
        case .power: return "^"
        }
    }

    // MARK: - Distribution (used by matches, never by simplify)

    /// Syntactic full distribution: products over sums, small integer powers
    /// of sums expanded by repeated multiplication. Bottom-up, recursive.
    static func distributed(_ expression: Expression) -> Expression {
        switch expression {
        case .number, .variable, .constant, .vector:
            return expression
        case .unary(let op, let operand):
            return .unary(op, distributed(operand))
        case .function(let name, let argument):
            return .function(name: name, argument: distributed(argument))
        case .binary(.power, let base, let exponent):
            let b = distributed(base)
            let e = distributed(exponent)
            // (a+b)^n for small positive integer n → repeated product.
            if case .number(let value) = e, value.isInteger, value.numerator > 1,
               value.numerator <= 6, isAdditive(b) {
                var product = b
                var i = 1
                while i < value.numerator {
                    product = distributed(.binary(.multiply, product, b))
                    i += 1
                }
                return product
            }
            return .binary(.power, b, e)
        case .binary(let op, let lhs, let rhs) where op == .multiply || op == .implicitMultiply:
            let l = distributed(lhs)
            let r = distributed(rhs)
            if let (a, addOp, b) = additiveParts(l) {
                let left = distributed(.binary(op, a, r))
                let right = distributed(.binary(op, b, r))
                return .binary(addOp, left, right)
            }
            if let (a, addOp, b) = additiveParts(r) {
                let left = distributed(.binary(op, l, a))
                let right = distributed(.binary(op, l, b))
                return .binary(addOp, left, right)
            }
            return .binary(op, l, r)
        case .binary(let op, let lhs, let rhs):
            return .binary(op, distributed(lhs), distributed(rhs))
        }
    }

    private static func isAdditive(_ expression: Expression) -> Bool {
        if case .binary(let op, _, _) = expression, op == .add || op == .subtract { return true }
        return false
    }

    private static func additiveParts(_ expression: Expression) -> (Expression, BinaryOperator, Expression)? {
        if case .binary(let op, let lhs, let rhs) = expression, op == .add || op == .subtract {
            return (lhs, op, rhs)
        }
        return nil
    }
}
