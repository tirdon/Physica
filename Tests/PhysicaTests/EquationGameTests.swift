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

@Suite @MainActor struct EquationGameTests {
    private func makeGame(
        _ source: String,
        goal: String? = nil,
        components: ComponentTable? = nil
    ) throws -> (Scene, EquationGame) {
        let scene = Scene()
        let provider = StubTokenGlyphProvider()
        let equation = EquationEntity(try Equation(parsing: source), provider: provider)
        let game = EquationGame(
            scene: scene, equation: equation,
            goal: goal.map { try! Equation(parsing: $0) },
            components: components, provider: provider
        )
        scene.add(equation)
        scene.seek(to: 0)
        scene.update(deltaTime: 0.016)  // lay out the first row
        return (scene, game)
    }

    /// Drags an editable-row token to one side of the '=' via raw input events.
    private func drag(_ game: EquationGame, token value: String, to side: EquationSide, in scene: Scene) {
        let row = game.equation.editableRow!
        guard let token = row.tokenEntities.first(where: { $0.components[TokenComponent.self]?.token.value == value }) else {
            Issue.record("no token '\(value)' in the editable row")
            return
        }
        let equalsX = row.equalsEntity!.worldBounds.center.x
        let y = row.equalsEntity!.worldBounds.center.y
        let start = token.worldBounds.center
        let targetX = side == .lhs ? equalsX - 0.4 : equalsX + 0.4
        scene.dispatch(.pointerDown(start))
        scene.dispatch(.pointerMoved(Position(start.x + 0.2, start.y, 0)))  // promote near source
        scene.dispatch(.pointerMoved(Position(targetX, y, 0)))              // drag to the side
        scene.dispatch(.pointerUp(Position(targetX, y, 0)))
        scene.update(deltaTime: 0.016)  // lay out the appended row
    }

    @Test func draggingAddendAcrossEqualsSubtractsBothSides() throws {
        let (scene, game) = try makeGame("2x + 3 = 5")
        drag(game, token: "3", to: .rhs, in: scene)
        #expect(game.equation.rows.count == 2)
        #expect(game.equation.current.matches(try Equation(parsing: "2x = 2")))
    }

    @Test func draggingCoefficientAcrossEqualsDividesBothSides() throws {
        let (scene, game) = try makeGame("2x = 6")
        drag(game, token: "2", to: .rhs, in: scene)
        #expect(game.equation.current.matches(try Equation(parsing: "x = 3")))
    }

    @Test func sameSideDropWithNothingToCombineIsRejected() throws {
        let (scene, game) = try makeGame("x = 5")
        drag(game, token: "x", to: .lhs, in: scene)
        #expect(game.equation.rows.count == 1)  // no row appended
    }

    @Test func externalMultiplierOntoSumOffersTwoChips() throws {
        let (scene, game) = try makeGame("y = a + b")
        let drop = game.equation.components[DropTargetComponent.self]!
        let equalsX = game.equation.editableRow!.equalsEntity!.worldBounds.center.x
        let external = Circle(radius: 0.1)
        external.position = Position(equalsX + 1, 0, 0)  // dropped on the rhs (a + b)
        let result = drop.onDrop!(.expression(try Expression(parsing: "c")), external)
        #expect(result == .accepted)
        #expect(game.chipEntities.count == 2)
        #expect(scene.drag.isEnabled == false)  // dragging locked while choosing
    }

    @Test func tappingChipCommitsAndDismisses() throws {
        let (scene, game) = try makeGame("y = a + b")
        let drop = game.equation.components[DropTargetComponent.self]!
        let equalsX = game.equation.editableRow!.equalsEntity!.worldBounds.center.x
        let external = Circle(radius: 0.1)
        external.position = Position(equalsX + 1, 0, 0)
        _ = drop.onDrop!(.expression(try Expression(parsing: "c")), external)
        let chip = game.chipEntities[0]
        scene.dispatch(.pointerDown(chip.position))
        scene.dispatch(.pointerUp(chip.position))
        #expect(game.equation.rows.count == 2)       // committed the chosen form
        #expect(game.chipEntities.isEmpty)           // chips dismissed
        #expect(scene.drag.isEnabled)                // dragging re-enabled
    }

    @Test func projectionDropSpawnsScalarEquations() throws {
        let components = try ComponentTable([
            "F": ("F_x", "0"),
            "g": ("0", "g"),
            "T": ("T\\cos\\theta", "T\\sin\\theta"),
        ])
        let (scene, game) = try makeGame("\\vec F = m\\vec g + \\vec T", components: components)
        let drop = game.equation.components[DropTargetComponent.self]!

        let xResult = drop.onDrop!(.projection(.x), Circle(radius: 0.1))
        #expect(xResult == .accepted)
        #expect(game.spawnedEquations.count == 1)
        #expect(game.spawnedEquations[0].current.matches(try Equation(parsing: "F_x = T\\cos\\theta")))
        #expect(scene.entities.contains { $0 === game.spawnedEquations[0] })

        _ = drop.onDrop!(.projection(.y), Circle(radius: 0.1))
        #expect(game.spawnedEquations.count == 2)
        #expect(game.spawnedEquations[1].current.matches(try Equation(parsing: "0 = mg + T\\sin\\theta")))
    }

    @Test func usedProjectionOperatorIsRetiredAndStaysGone() throws {
        let components = try ComponentTable([
            "F": ("F_x", "0"),
            "g": ("0", "g"),
            "T": ("T\\cos\\theta", "T\\sin\\theta"),
        ])
        let (scene, game) = try makeGame("\\vec F = m\\vec g + \\vec T", components: components)
        let drop = game.equation.components[DropTargetComponent.self]!

        // The operator chip enters via an `add` clip (a scene root).
        let op = Circle(radius: 0.3)
        op.name = "project-x"
        scene.insert(op)
        #expect(scene.entities.contains { $0 === op })

        #expect(drop.onDrop!(.projection(.x), op) == .accepted)
        #expect(!scene.entities.contains { $0 === op })  // consumed
        // A scrub re-seek replays the `add` (calls insert again) — retired → no-op.
        scene.insert(op)
        #expect(!scene.entities.contains { $0 === op })
    }

    @Test func spawnedEquationsStackWithoutOverlapping() throws {
        let components = try ComponentTable([
            "F": ("F_x", "0"),
            "g": ("0", "g"),
            "T": ("T\\cos\\theta", "T\\sin\\theta"),
        ])
        let (_, game) = try makeGame("\\vec F = m\\vec g + \\vec T", components: components)
        let drop = game.equation.components[DropTargetComponent.self]!
        _ = drop.onDrop!(.projection(.x), Circle(radius: 0.1))
        _ = drop.onDrop!(.projection(.y), Circle(radius: 0.1))
        #expect(game.spawnedEquations.count == 2)
        // The second projection lands strictly below the first (no pile-up at
        // the same y the way both keying off `equation.position` would give).
        #expect(game.spawnedEquations[1].position.y < game.spawnedEquations[0].position.y)
    }

    @Test func projectionWithoutComponentTableIsRejected() throws {
        let (_, game) = try makeGame("\\vec F = m\\vec g")
        let drop = game.equation.components[DropTargetComponent.self]!
        #expect(drop.onDrop!(.projection(.x), Circle(radius: 0.1)) == .rejected)
    }

    @Test func reachingGoalWinsExactlyOnce() throws {
        let (scene, game) = try makeGame("2x + 3 = 5", goal: "x = 1")
        var wins = 0
        game.onWin = { wins += 1 }
        drag(game, token: "3", to: .rhs, in: scene)  // 2x = 2
        #expect(!game.hasWon)
        drag(game, token: "2", to: .rhs, in: scene)  // x = 1 → win
        #expect(game.hasWon)
        #expect(wins == 1)
        // A further move does not re-fire onWin.
        drag(game, token: "1", to: .lhs, in: scene)
        #expect(wins == 1)
    }

    @Test func showHintRunsAnInteraction() throws {
        let (scene, game) = try makeGame("x = 5")
        #expect(scene.interactions.isIdle)
        game.showHint()
        #expect(!scene.interactions.isIdle)
    }

    @Test func fullPlaythroughViaDispatchOnly() throws {
        let (scene, game) = try makeGame("2x + 3 = 5", goal: "x = 1")
        // Solve it with nothing but pointer events.
        drag(game, token: "3", to: .rhs, in: scene)  // 2x = 2
        drag(game, token: "2", to: .rhs, in: scene)  // x = 1
        #expect(game.hasWon)
        #expect(game.equation.rows.count == 3)
        #expect(game.equation.current.matches(try Equation(parsing: "x = 1")))
    }
}
