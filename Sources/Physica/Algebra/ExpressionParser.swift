// Byte-level lexer + precedence-climbing parser for the TeX-ish grammar the
// game scripts use — deliberately not full TeX. Follows the Equalynx engine's
// wasm-safe style: UTF-8 byte scanning, no Foundation.
//
// Grammar notes:
//  - Letter runs are ONE name only when the whole run is a known function
//    (\sin-class) or greek name; otherwise letters split into single-letter
//    variables joined by implicit multiplication ("mg" → m·g).
//  - `F_x` / `F_{xy}` glue a subscript onto the preceding single letter.
//  - `\theta` → variable("theta"), `\vec F` / `\vec{F}` → vector("F"),
//    `\frac{a}{b}` → divide, `\cdot`/`\times`/`*` → multiply, `^` → power
//    (right-associative), juxtaposition → implicitMultiply.
//  - "pi" / `\pi` is a constant; everything else lexes as a variable.

enum AlgebraToken: Equatable {
    case number(Rational)
    case name(String)
    case functionName(String)
    case vectorName(String)
    case frac
    case plus, minus, times, divide, power
    case leftParen, rightParen
    case leftBrace, rightBrace
}

enum ExpressionParser {
    static func parse(_ source: String) throws -> Expression {
        var lexer = AlgebraLexer(source)
        let tokens = try lexer.tokenize()
        guard !tokens.isEmpty else {
            throw AlgebraError.parse("Nothing to parse.")
        }
        var parser = TokenParser(tokens: tokens)
        let expression = try parser.parseExpression()
        guard parser.isAtEnd else {
            throw AlgebraError.parse("Unexpected trailing input.")
        }
        return expression
    }
}

// MARK: - Lexer

struct AlgebraLexer {
    private let bytes: [UInt8]
    private var index = 0

    init(_ source: String) {
        bytes = Array(source.utf8)
    }

    mutating func tokenize() throws -> [AlgebraToken] {
        var tokens: [AlgebraToken] = []
        while index < bytes.count {
            let byte = bytes[index]
            switch byte {
            case 32, 9, 10, 13: // whitespace
                index += 1
            case 48...57, 46: // digit or '.'
                tokens.append(.number(try lexNumber()))
            case 43: index += 1; tokens.append(.plus)
            case 45: index += 1; tokens.append(.minus)
            case 42: index += 1; tokens.append(.times)
            case 47: index += 1; tokens.append(.divide)
            case 94: index += 1; tokens.append(.power)
            case 40: index += 1; tokens.append(.leftParen)
            case 41: index += 1; tokens.append(.rightParen)
            case 123: index += 1; tokens.append(.leftBrace)
            case 125: index += 1; tokens.append(.rightBrace)
            case 92: // backslash
                if let token = try lexCommand() {
                    tokens.append(token)
                }
            case 61: // '='
                throw AlgebraError.parse("Unexpected '=' — parse equations with Equation(parsing:).")
            case 95: // '_'
                throw AlgebraError.parse("A subscript needs a letter before it.")
            default:
                guard isLetter(byte) else {
                    throw AlgebraError.parse("Unexpected character '\(String(decoding: [byte], as: UTF8.self))'.")
                }
                tokens.append(lexName())
            }
        }
        return tokens
    }

    private mutating func lexNumber() throws -> Rational {
        let start = index
        while index < bytes.count, (bytes[index] >= 48 && bytes[index] <= 57) || bytes[index] == 46 {
            index += 1
        }
        let literal = String(decoding: bytes[start..<index], as: UTF8.self)
        return try Rational(decimalText: literal)
    }

    /// A run of letters. Whole-run match against known function/greek names
    /// wins; otherwise consume ONE letter (plus any `_` subscript).
    private mutating func lexName() -> AlgebraToken {
        var end = index
        while end < bytes.count, isLetter(bytes[end]) {
            end += 1
        }
        let run = String(decoding: bytes[index..<end], as: UTF8.self)
        if Expression.functionNames.contains(run) {
            index = end
            return .functionName(run)
        }
        if Expression.greekNames.contains(run) || run == "pi" {
            index = end
            return .name(run)
        }
        var name = String(decoding: [bytes[index]], as: UTF8.self)
        index += 1
        if let sub = lexSubscript() {
            name += "_" + sub
        }
        return .name(name)
    }

    /// `_x`, `_2`, `_{xy}`, `_{\theta}` after a name. Nil when no subscript.
    private mutating func lexSubscript() -> String? {
        guard index < bytes.count, bytes[index] == 95 else { return nil }
        index += 1
        guard index < bytes.count else { return "" }
        if bytes[index] == 123 { // '{'
            index += 1
            var content: [UInt8] = []
            while index < bytes.count, bytes[index] != 125 {
                if bytes[index] != 92 { // strip backslashes: {\theta} → theta
                    content.append(bytes[index])
                }
                index += 1
            }
            if index < bytes.count { index += 1 } // consume '}'
            return String(decoding: content, as: UTF8.self)
        }
        if bytes[index] == 92 { // '\greek'
            index += 1
            return readLetterRun()
        }
        let sub = String(decoding: [bytes[index]], as: UTF8.self)
        index += 1
        return sub
    }

    /// Token after a backslash. Nil means "skip" (\left / \right).
    private mutating func lexCommand() throws -> AlgebraToken? {
        index += 1 // consume backslash
        let command = readLetterRun()
        switch command {
        case "cdot", "times": return .times
        case "div": return .divide
        case "left", "right": return nil
        case "frac": return .frac
        case "vec": return .vectorName(try lexVectorName())
        case _ where Expression.functionNames.contains(command):
            return .functionName(command)
        case "":
            throw AlgebraError.parse("Dangling backslash.")
        default:
            // Greek and any unknown command lex as an identifier (\hbar etc.).
            var name = command
            if let sub = lexSubscript() {
                name += "_" + sub
            }
            return .name(name)
        }
    }

    /// The identifier after \vec: a single letter, \greek, or {name}.
    private mutating func lexVectorName() throws -> String {
        skipSpaces()
        guard index < bytes.count else {
            throw AlgebraError.parse("\\vec needs an identifier.")
        }
        if bytes[index] == 123 { // '{...}'
            index += 1
            var content: [UInt8] = []
            while index < bytes.count, bytes[index] != 125 {
                if bytes[index] != 92 {
                    content.append(bytes[index])
                }
                index += 1
            }
            guard index < bytes.count else {
                throw AlgebraError.parse("Unterminated \\vec{…}.")
            }
            index += 1
            return String(decoding: content, as: UTF8.self)
        }
        if bytes[index] == 92 { // \greek
            index += 1
            return readLetterRun()
        }
        guard isLetter(bytes[index]) else {
            throw AlgebraError.parse("\\vec needs an identifier.")
        }
        var name = String(decoding: [bytes[index]], as: UTF8.self)
        index += 1
        if let sub = lexSubscript() {
            name += "_" + sub
        }
        return name
    }

    private mutating func readLetterRun() -> String {
        let start = index
        while index < bytes.count, isLetter(bytes[index]) {
            index += 1
        }
        return String(decoding: bytes[start..<index], as: UTF8.self)
    }

    private mutating func skipSpaces() {
        while index < bytes.count, bytes[index] == 32 {
            index += 1
        }
    }

    private func isLetter(_ byte: UInt8) -> Bool {
        (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122)
    }
}

// MARK: - Parser

private struct TokenParser {
    let tokens: [AlgebraToken]
    var index = 0

    var isAtEnd: Bool { index >= tokens.count }

    private func peek() -> AlgebraToken? {
        index < tokens.count ? tokens[index] : nil
    }

    private mutating func advance() {
        index += 1
    }

    // additive
    mutating func parseExpression() throws -> Expression {
        var result = try parseTerm()
        while let token = peek() {
            if token == .plus {
                advance()
                result = .binary(.add, result, try parseTerm())
            } else if token == .minus {
                advance()
                result = .binary(.subtract, result, try parseTerm())
            } else {
                break
            }
        }
        return result
    }

    // multiplicative, including juxtaposition
    private mutating func parseTerm() throws -> Expression {
        var result = try parseUnary()
        loop: while let token = peek() {
            switch token {
            case .times:
                advance()
                result = .binary(.multiply, result, try parseUnary())
            case .divide:
                advance()
                result = .binary(.divide, result, try parseUnary())
            case .number, .name, .functionName, .vectorName, .frac, .leftParen:
                result = .binary(.implicitMultiply, result, try parsePower())
            default:
                break loop
            }
        }
        return result
    }

    private mutating func parseUnary() throws -> Expression {
        var negative = false
        while let token = peek() {
            if token == .minus {
                advance()
                negative.toggle()
            } else if token == .plus {
                advance()
            } else {
                break
            }
        }
        let operand = try parsePower()
        return negative ? .unary(.minus, operand) : operand
    }

    private mutating func parsePower() throws -> Expression {
        let base = try parsePrimary()
        if peek() == .power {
            advance()
            // Right-associative; the exponent may carry its own sign (x^-2).
            let exponent = try parseUnary()
            return .binary(.power, base, exponent)
        }
        return base
    }

    private mutating func parsePrimary() throws -> Expression {
        guard let token = peek() else {
            throw AlgebraError.parse("Expected a value.")
        }
        switch token {
        case .number(let value):
            advance()
            return .number(value)
        case .name(let name):
            advance()
            return name == "pi" ? .constant(name) : .variable(name)
        case .vectorName(let name):
            advance()
            return .vector(name)
        case .functionName(let name):
            advance()
            // The argument binds tight: \cos\theta, \cos(a+b), \cos x^2.
            return .function(name: name, argument: try parsePower())
        case .frac:
            advance()
            let numerator = try parseGroup()
            let denominator = try parseGroup()
            return .binary(.divide, numerator, denominator)
        case .leftParen:
            advance()
            let inner = try parseExpression()
            guard peek() == .rightParen else {
                throw AlgebraError.parse("Missing ')'.")
            }
            advance()
            return inner
        case .leftBrace:
            return try parseGroup()
        default:
            throw AlgebraError.parse("Expected a value.")
        }
    }

    private mutating func parseGroup() throws -> Expression {
        guard peek() == .leftBrace else {
            throw AlgebraError.parse("Expected '{'.")
        }
        advance()
        let inner = try parseExpression()
        guard peek() == .rightBrace else {
            throw AlgebraError.parse("Missing '}'.")
        }
        advance()
        return inner
    }
}
