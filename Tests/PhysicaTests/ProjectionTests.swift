import Testing
@testable import Physica

@Suite @MainActor struct ProjectionTests {
    /// The pendulum-force table from the feature spec.
    private func forceTable() throws -> ComponentTable {
        try ComponentTable([
            "F": (x: "F_x", y: "0"),
            "g": (x: "0", y: "g"),
            "T": (x: "T\\cos\\theta", y: "T\\sin\\theta"),
        ])
    }

    @Test func componentTableParsesEntriesEagerly() throws {
        let table = try forceTable()
        #expect(table.component(of: "g", axis: .y) == .variable("g"))
        #expect(table.component(of: "g", axis: .x) == .number(.zero))
        #expect(table.component(of: "missing", axis: .x) == nil)
        #expect(table.vectorNames == ["F", "T", "g"])
    }

    @Test func badEntryThrowsAtInit() {
        #expect(throws: AlgebraError.self) {
            _ = try ComponentTable(["F": (x: "3 +", y: "0")])
        }
    }

    @Test func xProjectionGivesScalarComponentEquation() throws {
        let vector = try Equation(parsing: "\\vec F = m\\vec g + \\vec T")
        let scalar = try vector.projected(onto: .x, components: forceTable())
        // m·0 folds away entirely.
        #expect(scalar == (try Equation(parsing: "F_x = T\\cos\\theta").simplified()))
    }

    @Test func yProjectionZeroesTheLHS() throws {
        let vector = try Equation(parsing: "\\vec F = m\\vec g + \\vec T")
        let scalar = try vector.projected(onto: .y, components: forceTable())
        #expect(scalar.lhs == .number(.zero))
        #expect(scalar == (try Equation(parsing: "0 = mg + T\\sin\\theta").simplified()))
    }

    @Test func missingVectorInTableThrows() throws {
        let table = try ComponentTable(["F": (x: "F_x", y: "0")])
        let vector = try Equation(parsing: "\\vec F = \\vec T")
        #expect(throws: AlgebraError.self) {
            _ = try vector.projected(onto: .x, components: table)
        }
    }

    @Test func scalarEquationUnchangedByProjection() throws {
        let scalar = try Equation(parsing: "2x + 3 = 5")
        let projected = try scalar.projected(onto: .x, components: forceTable())
        #expect(projected == (try scalar.simplified()))
    }

    @Test func projectionComposesWithMoves() throws {
        // Project, then solve the scalar equation with a drag move.
        let vector = try Equation(parsing: "\\vec F = m\\vec g + \\vec T")
        let scalar = try vector.projected(onto: .y, components: forceTable())
        // 0 = mg + T sinθ → drag mg across → -mg = T sinθ.
        let tokens = scalar.buildTokens()
        let mgAddress = tokens.first { $0.value == "m" }?.address
        #expect(mgAddress != nil)
        guard case .resolved(let moved) = scalar.movingTerm(at: mgAddress!, to: .lhs) else {
            Issue.record("Expected resolved move")
            return
        }
        #expect(moved.matches(try Equation(parsing: "-mg = T\\sin\\theta")))
    }
}
