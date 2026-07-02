import Testing
@testable import PhysicaMath
@testable import PhysicaAlgebra
@testable import PhysicaGeometry
@testable import PhysicaTypesetting
@testable import PhysicaKernel
@testable import PhysicaPlotting
@testable import PhysicaStory
@testable import PhysicaPhysics
@testable import PhysicaEquationGame

// MARK: - Rational

@Suite @MainActor struct RationalTests {
    @Test func gcdNormalizationAtInit() throws {
        let value = try Rational(6, over: -4)
        #expect(value.numerator == -3)
        #expect(value.denominator == 2)
        #expect(Rational(5).denominator == 1)
    }

    @Test func arithmeticStaysExact() throws {
        let sum = try Rational(1, over: 3) + Rational(1, over: 6)
        #expect(sum == (try Rational(1, over: 2)))
        let product = try Rational(3, over: 2) * Rational(2, over: 9)
        #expect(product == (try Rational(1, over: 3)))
        let quotient = try Rational(3) / Rational(2)
        #expect(quotient == (try Rational(3, over: 2)))
        let difference = try Rational(1, over: 2) - Rational(1, over: 2)
        #expect(difference.isZero)
    }

    @Test func divisionByZeroThrows() {
        #expect(throws: AlgebraError.divisionByZero) {
            _ = try Rational(1, over: 0)
        }
        #expect(throws: AlgebraError.divisionByZero) {
            _ = try Rational(1) / Rational(0)
        }
        #expect(throws: AlgebraError.divisionByZero) {
            _ = try Rational(0).raised(to: -1)
        }
    }

    @Test func overflowThrows() {
        #expect(throws: AlgebraError.overflow) {
            _ = try Rational(Int.max) * Rational(2)
        }
        #expect(throws: AlgebraError.overflow) {
            _ = try Rational(Int.max) + Rational(1)
        }
    }

    @Test func displayTextAndDecimalParsing() throws {
        #expect(Rational(3).displayText == "3")
        #expect(try Rational(3, over: 2).displayText == "3/2")
        #expect(try Rational(-3, over: 2).displayText == "-3/2")
        #expect(try Rational(decimalText: "0.5") == Rational(1, over: 2))
        #expect(try Rational(decimalText: "3.50") == Rational(7, over: 2))
        #expect(throws: AlgebraError.self) {
            _ = try Rational(decimalText: "3.5.0")
        }
    }

    @Test func integerPowers() throws {
        #expect(try Rational(2).raised(to: 3) == Rational(8))
        #expect(try Rational(2).raised(to: -2) == Rational(1, over: 4))
        #expect(try Rational(7).raised(to: 0) == Rational(1))
    }
}

// MARK: - Parser

@Suite @MainActor struct ExpressionParserTests {
    @Test func parsesImplicitMultiplyJuxtaposition() throws {
        #expect(try Expression(parsing: "2x")
            == .binary(.implicitMultiply, .number(Rational(2)), .variable("x")))
        #expect(try Expression(parsing: "m g")
            == .binary(.implicitMultiply, .variable("m"), .variable("g")))
        // Unknown letter runs split into single-letter variables.
        #expect(try Expression(parsing: "mg")
            == .binary(.implicitMultiply, .variable("m"), .variable("g")))
    }

    @Test func parsesTexIdentifiers() throws {
        #expect(try Expression(parsing: "\\theta") == .variable("theta"))
        #expect(try Expression(parsing: "theta") == .variable("theta"))
        #expect(try Expression(parsing: "F_x") == .variable("F_x"))
        #expect(try Expression(parsing: "F_{xy}") == .variable("F_xy"))
        #expect(try Expression(parsing: "\\pi") == .constant("pi"))
    }

    @Test func parsesVecToVectorCase() throws {
        #expect(try Expression(parsing: "\\vec F") == .vector("F"))
        #expect(try Expression(parsing: "\\vec{T}") == .vector("T"))
        #expect(try Expression(parsing: "m\\vec g")
            == .binary(.implicitMultiply, .variable("m"), .vector("g")))
    }

    @Test func parsesFracAsDivide() throws {
        #expect(try Expression(parsing: "\\frac{g}{\\ell}")
            == .binary(.divide, .variable("g"), .variable("ell")))
    }

    @Test func parsesFunctionApplication() throws {
        #expect(try Expression(parsing: "T\\cos\\theta")
            == .binary(.implicitMultiply, .variable("T"),
                       .function(name: "cos", argument: .variable("theta"))))
        #expect(try Expression(parsing: "\\sin(a + b)")
            == .function(name: "sin", argument: .binary(.add, .variable("a"), .variable("b"))))
    }

    @Test func unaryMinusAndPowerPrecedence() throws {
        let negated = try Expression(parsing: "-2x").simplified()
        let subtracted = try Expression(parsing: "0 - 2x").simplified()
        #expect(negated == subtracted)
        // Right-associative power: x^2^3 = x^(2^3) = x^8.
        let chained = try Expression(parsing: "x^2^3").simplified()
        let direct = try Expression(parsing: "x^8").simplified()
        #expect(chained == direct)
    }

    @Test func parseErrorsThrow() {
        #expect(throws: AlgebraError.self) { _ = try Expression(parsing: "3 +") }
        #expect(throws: AlgebraError.self) { _ = try Expression(parsing: "") }
        #expect(throws: AlgebraError.self) { _ = try Expression(parsing: ")(") }
        #expect(throws: AlgebraError.self) { _ = try Expression(parsing: "a = b") }
        #expect(throws: AlgebraError.self) { _ = try Equation(parsing: "3 + 5") }
    }

    @Test func equationSplitsOnFirstTopLevelEquals() throws {
        let equation = try Equation(parsing: "3 + 5 = 8")
        #expect(equation.lhs == .binary(.add, .number(Rational(3)), .number(Rational(5))))
        #expect(equation.rhs == .number(Rational(8)))
    }
}

// MARK: - Simplifier

@Suite @MainActor struct SimplifierTests {
    private func canonical(_ source: String) throws -> Expression {
        try Expression(parsing: source).simplified()
    }

    @Test func likeTermCollection() throws {
        #expect(try canonical("2x + 3x") == canonical("5x"))
        #expect(try canonical("x + x") == canonical("2x"))
        #expect(try canonical("3x + 2y - x") == canonical("2x + 2y"))
    }

    @Test func identityRules() throws {
        #expect(try canonical("x + 0") == canonical("x"))
        #expect(try canonical("x * 1") == canonical("x"))
        #expect(try canonical("x * 0") == Expression.number(.zero))
        #expect(try canonical("x^1") == canonical("x"))
        #expect(try canonical("x^0") == Expression.number(.one))
        #expect(try canonical("--x") == canonical("x"))
    }

    @Test func constantFoldingStaysExact() throws {
        #expect(try canonical("3 + 5") == Expression.number(Rational(8)))
        #expect(try canonical("1/3 + 1/6") == Expression.number(Rational(1, over: 2)))
        #expect(try canonical("2^3") == Expression.number(Rational(8)))
        #expect(try canonical("(2x)^2") == canonical("4x^2"))
    }

    @Test func commutativeCanonicalOrder() throws {
        #expect(try canonical("b a") == canonical("a b"))
        #expect(try canonical("y + x") == canonical("x + y"))
        #expect(try canonical("x x") == canonical("x^2"))
    }

    @Test func associativeFlatten() throws {
        #expect(try canonical("(a + b) + c") == canonical("a + (b + c)"))
        #expect(try canonical("(a b) c") == canonical("a (b c)"))
    }

    @Test func distributedMatchesFactoredButStaysFactored() throws {
        let factored = try Expression(parsing: "c(a + b)")
        let expanded = try Expression(parsing: "ca + cb")
        #expect(factored.matches(expanded))
        #expect(expanded.matches(factored))
        // simplify alone must NOT distribute.
        #expect(try factored.simplified() != expanded.simplified())
        #expect(!factored.matches(try Expression(parsing: "ca + b")))
    }

    @Test func divisionByZeroDuringFoldThrows() {
        #expect(throws: AlgebraError.divisionByZero) {
            _ = try Expression(parsing: "1/0").simplified()
        }
        #expect(throws: AlgebraError.divisionByZero) {
            _ = try Expression(parsing: "x/0").simplified()
        }
    }

    @Test func functionsAndVectorsStayAtomic() throws {
        #expect(try canonical("\\sin\\theta \\sin\\theta")
            == canonical("(\\sin\\theta)^2"))
        let projected = try canonical("m\\vec g + \\vec T")
        #expect(projected.containsVector)
    }
}

// MARK: - Moves

@Suite @MainActor struct EquationMoveTests {
    private func equation(_ source: String) throws -> Equation {
        try Equation(parsing: source)
    }

    private func expectResolved(_ outcome: MoveOutcome, _ expected: String) throws {
        guard case .resolved(let result) = outcome else {
            Issue.record("Expected resolved, got \(outcome)")
            return
        }
        let target = try Equation(parsing: expected).simplified()
        #expect(result == target, "got \(result.tex), wanted \(target.tex)")
    }

    @Test func sameSideMergeCombinesTerms() throws {
        let outcome = try equation("3 + 5 = 8")
            .movingTerm(at: TokenAddress(side: .lhs, termIndex: 0), to: .lhs)
        try expectResolved(outcome, "8 = 8")
    }

    @Test func crossSideAddendSubtractsBothSides() throws {
        let outcome = try equation("2x + 3 = 5")
            .movingTerm(at: TokenAddress(side: .lhs, termIndex: 1), to: .rhs)
        try expectResolved(outcome, "2x = 2")
    }

    @Test func crossSideCoefficientDividesBothSides() throws {
        let solved = try equation("2x = 2")
            .movingTerm(at: TokenAddress(side: .lhs, termIndex: 0, factorIndex: 0), to: .rhs)
        try expectResolved(solved, "x = 1")
        // Exact fraction, no rounding.
        let fraction = try equation("2x = 3")
            .movingTerm(at: TokenAddress(side: .lhs, termIndex: 0, factorIndex: 0), to: .rhs)
        guard case .resolved(let result) = fraction else {
            Issue.record("Expected resolved")
            return
        }
        #expect(result.rhs == .number(try Rational(3, over: 2)))
    }

    @Test func symbolicFactorMovesWholeTerm() throws {
        // Dragging the x of 2x across moves the whole 2x term (Equalynx rule).
        let outcome = try equation("2x + 3 = 5")
            .movingTerm(at: TokenAddress(side: .lhs, termIndex: 0, factorIndex: 1), to: .rhs)
        try expectResolved(outcome, "3 = -2x + 5")
    }

    @Test func fullLinearSolvePath() throws {
        var current = try equation("2x + 3 = 5")
        guard case .resolved(let step1) = current
            .movingTerm(at: TokenAddress(side: .lhs, termIndex: 1), to: .rhs) else {
            Issue.record("step 1 failed")
            return
        }
        current = step1
        guard case .resolved(let step2) = current
            .movingTerm(at: TokenAddress(side: .lhs, termIndex: 0, factorIndex: 0), to: .rhs) else {
            Issue.record("step 2 failed")
            return
        }
        #expect(step2 == (try Equation(parsing: "x = 1").simplified()))
    }

    @Test func multiplierOntoSumReturnsBothChoices() throws {
        let outcome = try equation("a + b = d")
            .applying(.variable("c"), asRole: .factor, to: .lhs)
        guard case .choice(let choices) = outcome else {
            Issue.record("Expected choice, got \(outcome)")
            return
        }
        #expect(choices.count == 2)
        let factored = try Equation(parsing: "c(a + b) = cd")
        let distributed = try Equation(parsing: "ca + cb = cd")
        #expect(choices[0].value.matches(factored))
        #expect(choices[1].value.matches(distributed))
        // The two displays differ structurally even though they match.
        #expect(choices[0].value != choices[1].value)
        #expect(!choices[0].label.isEmpty)
        #expect(!choices[1].label.isEmpty)
    }

    @Test func addendApplyKeepsEquationBalanced() throws {
        let outcome = try equation("x = 5")
            .applying(.number(Rational(3)), asRole: .addend, to: .lhs)
        try expectResolved(outcome, "x + 3 = 8")
    }

    @Test func rejectedMovesCarryReasons() throws {
        // Already canonical: nothing to combine on the same side.
        let merge = try equation("x = 1")
            .movingTerm(at: TokenAddress(side: .lhs, termIndex: 0), to: .lhs)
        guard case .rejected(let reason) = merge else {
            Issue.record("Expected rejection")
            return
        }
        #expect(!reason.isEmpty)
        // Out-of-range address.
        let outOfRange = try equation("x = 1")
            .movingTerm(at: TokenAddress(side: .lhs, termIndex: 7), to: .rhs)
        guard case .rejected = outOfRange else {
            Issue.record("Expected rejection")
            return
        }
        // Multiplying by zero.
        let zero = try equation("x = 1")
            .applying(.number(.zero), asRole: .factor, to: .lhs)
        guard case .rejected = zero else {
            Issue.record("Expected rejection")
            return
        }
    }
}

// MARK: - Display tokens

@Suite @MainActor struct DisplayTokenTests {
    @Test func readingOrderWithAddresses() throws {
        let tokens = try Equation(parsing: "3 + 5 = 8").buildTokens()
        #expect(tokens.map(\.value) == ["3", "+", "5", "=", "8"])
        #expect(tokens[0].address == TokenAddress(side: .lhs, termIndex: 0))
        #expect(tokens[1].address == nil)
        #expect(tokens[2].address == TokenAddress(side: .lhs, termIndex: 1))
        #expect(tokens[3].kind == .equals)
        #expect(tokens[4].address == TokenAddress(side: .rhs, termIndex: 0))
    }

    @Test func implicitMultiplyEmitsNoTokenAndGlues() throws {
        let tokens = try Equation(parsing: "2x + 3 = 5").buildTokens()
        #expect(tokens.map(\.value) == ["2", "x", "+", "3", "=", "5"])
        #expect(tokens[1].glue)
        #expect(!tokens[0].glue)
        #expect(tokens[0].address == TokenAddress(side: .lhs, termIndex: 0, factorIndex: 0))
        #expect(tokens[1].address == TokenAddress(side: .lhs, termIndex: 0, factorIndex: 1))
        #expect(tokens[3].address == TokenAddress(side: .lhs, termIndex: 1, factorIndex: nil))
    }

    @Test func divideFoldsToSingleFracToken() throws {
        let tokens = try Equation(parsing: "x = 3/2").simplified().buildTokens()
        #expect(tokens.count == 3)
        #expect(tokens[2].tex == "\\frac{3}{2}")
        #expect(tokens[2].kind == .number)
        #expect(tokens[2].value == "3/2")
    }

    @Test func functionTokenStaysWholeAndGlued() throws {
        let tokens = try Equation(parsing: "F_x = T\\cos\\theta").buildTokens()
        // F_x, =, T, cos θ — the function hugs its coefficient.
        #expect(tokens.count == 4)
        #expect(tokens[0].tex == "F_x")
        #expect(tokens[3].kind == .function)
        #expect(tokens[3].glue)
        #expect(tokens[3].tex.contains("\\cos"))
        #expect(tokens[3].tex.contains("\\theta"))
    }

    @Test func vectorEquationTokens() throws {
        let tokens = try Equation(parsing: "\\vec F = m\\vec g + \\vec T").buildTokens()
        #expect(tokens.map(\.kind) == [.vector, .equals, .variable, .vector, .op, .vector])
        #expect(tokens[0].tex == "\\vec{F}")
        #expect(tokens[3].glue)
        let negativeFirst = try Equation(parsing: "0 = mg + T\\sin\\theta").buildTokens()
        #expect(negativeFirst.map(\.value) == ["0", "=", "m", "g", "+", "T", "sin θ"])
    }

    @Test func addressesRoundTripThroughTermAt() throws {
        let equation = try Equation(parsing: "2x + 3 = 5")
        let tokens = equation.buildTokens()
        for token in tokens {
            guard let address = token.address else { continue }
            #expect(equation.term(at: address) != nil)
        }
        // The coefficient address resolves to the number 2.
        let coefficient = equation.term(at: TokenAddress(side: .lhs, termIndex: 0, factorIndex: 0))
        #expect(coefficient == .number(Rational(2)))
        // The whole-term address resolves to the signed term.
        let constant = equation.term(at: TokenAddress(side: .lhs, termIndex: 1))
        #expect(constant == .number(Rational(3)))
    }

    @Test func parenthesizedSumIsOneToken() throws {
        let equation = try Equation(parsing: "c(a + b) = d")
        let tokens = equation.buildTokens()
        #expect(tokens.map(\.glue) == [false, true, false, false])
        #expect(tokens[1].tex == "\\left(a + b\\right)")
        #expect(tokens[1].value == "(a + b)")
    }
}
