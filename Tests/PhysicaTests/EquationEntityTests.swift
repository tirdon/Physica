import Foundation
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

@Suite @MainActor struct EquationEntityTests {
    private let tolerance: Real = 1e-4

    private func glyphSquares(_ count: Int, width: Real = 0.4, step: Real = 0.5) -> [TextComponent.PositionedGlyph] {
        (0..<count).map { index in
            TextComponent.PositionedGlyph(
                path: Path.rect(width: width, height: width, center: SIMD2(Real(index) * step, 0)),
                offset: .zero
            )
        }
    }

    // MARK: Row layout

    @Test func oneTokenEntityPerToken() throws {
        let equation = try Equation(parsing: "2x = 5")
        let scene = Scene()
        let eq = EquationEntity(equation, provider: StubTokenGlyphProvider())
        scene.add(eq)
        scene.seek(to: 0)
        scene.update(deltaTime: 0.016)
        #expect(eq.rows[0].tokenEntities.count == equation.buildTokens().count)
        #expect(eq.rows[0].tokens.map(\.value) == ["2", "x", "=", "5"])
    }

    @Test func gluedFactorHugsItsNeighbor() throws {
        let scene = Scene()
        let eq = EquationEntity(try Equation(parsing: "2x = 5"), provider: StubTokenGlyphProvider())
        scene.add(eq)
        scene.seek(to: 0)
        scene.update(deltaTime: 0.016)
        let row = eq.rows[0]
        // "2" right edge (0 + 0.5) meets "x" left edge (0.5) — zero gap.
        let twoRight = row.tokenEntities[0].position.x + 0.5
        let xLeft = row.tokenEntities[1].position.x
        #expect(abs(xLeft - twoRight) < tolerance)
    }

    @Test func equalsTokenGetsItsGap() throws {
        let scene = Scene()
        let eq = EquationEntity(try Equation(parsing: "2x = 5"), provider: StubTokenGlyphProvider(),
                                style: EquationStyle(equalsGap: 0.28))
        scene.add(eq)
        scene.seek(to: 0)
        scene.update(deltaTime: 0.016)
        let row = eq.rows[0]
        let xRight = row.tokenEntities[1].position.x + 0.5
        let equalsLeft = row.tokenEntities[2].position.x
        #expect(abs((equalsLeft - xRight) - 0.28) < tolerance)
    }

    // MARK: Column '=' alignment

    @Test func equalsAlignsAcrossRowsOfDifferentWidth() throws {
        let scene = Scene()
        let eq = EquationEntity(try Equation(parsing: "2x = 5"), provider: StubTokenGlyphProvider())
        eq.appendRow(try Equation(parsing: "x = 3"))  // narrower LHS
        scene.add(eq)
        scene.seek(to: 0)
        scene.update(deltaTime: 0.016)
        let x0 = eq.rows[0].equalsEntity!.worldBounds.center.x
        let x1 = eq.rows[1].equalsEntity!.worldBounds.center.x
        #expect(abs(x0 - x1) < tolerance)
    }

    @Test func continuationRowAlignsOnEquals() throws {
        let scene = Scene()
        let eq = EquationEntity(try Equation(parsing: "2x = 5"), provider: StubTokenGlyphProvider())
        eq.appendRow(try Equation(parsing: "0 = 7"), showsLHS: false)  // renders "= 7"
        scene.add(eq)
        scene.seek(to: 0)
        scene.update(deltaTime: 0.016)
        let continuation = eq.rows[1]
        #expect(continuation.tokens.first?.kind == .equals)  // starts at '='
        let x0 = eq.rows[0].equalsEntity!.worldBounds.center.x
        let x1 = continuation.equalsEntity!.worldBounds.center.x
        #expect(abs(x0 - x1) < tolerance)
    }

    // MARK: Rows lifecycle

    @Test func appendRowFreezesPreviousAndKeepsNewActive() throws {
        let eq = EquationEntity(try Equation(parsing: "x = 5"), provider: StubTokenGlyphProvider())
        eq.appendRow(try Equation(parsing: "x = 6"))  // not in a scene → opacity set immediately
        let frozen = eq.rows[0].tokenEntities[0].components[RenderStyleComponent.self]!.opacity
        let active = eq.rows[1].tokenEntities[0].components[RenderStyleComponent.self]!.opacity
        #expect(abs(frozen - eq.style.inactiveRowOpacity) < tolerance)
        #expect(abs(active - 1) < tolerance)
    }

    @Test func currentIsLastRowOnlyLastEditable() throws {
        let eq = EquationEntity(try Equation(parsing: "x = 5"), provider: StubTokenGlyphProvider())
        #expect(eq.rows[0].isInteractive)
        let last = try Equation(parsing: "x = 9")
        eq.appendRow(last)
        #expect(eq.current == last)
        #expect(!eq.rows[0].isInteractive)
        #expect(eq.rows[1].isInteractive)
        // The editable row's addressable tokens carry drag handles.
        #expect(eq.rows[1].tokenEntities.contains { $0.components[DraggableComponent.self] != nil })
        #expect(!eq.rows[0].tokenEntities.contains { $0.components[DraggableComponent.self] != nil })
    }

    // MARK: makeLiteral

    @Test func makeLiteralClonesClampedSlice() {
        let formula = TextEntity(glyphs: glyphSquares(5), fontSize: 1)
        #expect(formula[1..<3].makeLiteral(.identifier("x")).textComponent.glyphs.count == 2)
        #expect(formula[3...].makeLiteral(.symbolic("y")).textComponent.glyphs.count == 2)
        // Out-of-range clamps to empty rather than trapping.
        #expect(formula[10..<20].makeLiteral(.numerical("0")).textComponent.glyphs.count == 0)
    }

    @Test func literalPayloadParsesFromKind() {
        #expect(LiteralKind.identifier("x").payload == .expression(.variable("x")))
        #expect(LiteralKind.projection(.x).payload == .projection(.x))
    }

    @Test func literalFollowsSourceUntilGrabbed() {
        let scene = Scene()
        let formula = TextEntity(glyphs: glyphSquares(5), fontSize: 1)
        formula.position = Position(2, 1, 0)
        scene.add(formula)
        scene.seek(to: 0)

        let literal = formula[0..<2].makeLiteral(.identifier("x"))
        scene.add(literal)
        scene.seek(to: 0)
        #expect(literal.isFollowingSource)

        scene.update(deltaTime: 0.016)
        let followedX = literal.position.x
        formula.position = Position(6, 1, 0)  // source moves
        scene.update(deltaTime: 0.016)
        #expect(literal.position.x > followedX + 1)  // literal tracked it

        // Grabbing it detaches the follow.
        scene.dispatch(.pointerDown(literal.position))
        scene.dispatch(.pointerMoved(literal.position + Position(0.4, 0, 0)))
        #expect(!literal.isFollowingSource)
    }

    // MARK: Placeholder

    @Test func placeholderAcceptsMatchAndReportsFill() throws {
        let placeholder = PlaceholderEquationEntity(target: try Expression(parsing: "T\\cos\\theta"))
        var reported: Bool?
        placeholder.onFill = { _, isMatch in reported = isMatch }
        let drop = placeholder.components[DropTargetComponent.self]!
        let result = drop.onDrop!(.expression(try Expression(parsing: "T\\cos\\theta")), Circle(radius: 0.1))
        #expect(result == .accepted)
        #expect(reported == true)
        #expect(placeholder.isFilled)
    }

    @Test func placeholderMatchesViaSimplifier() throws {
        // Commuted product still matches (matches() simplifies both sides).
        let placeholder = PlaceholderEquationEntity(target: try Expression(parsing: "2x"))
        let drop = placeholder.components[DropTargetComponent.self]!
        let result = drop.onDrop!(.expression(try Expression(parsing: "x \\cdot 2")), Circle(radius: 0.1))
        #expect(result == .accepted)
    }

    @Test func placeholderRejectsMismatch() throws {
        let placeholder = PlaceholderEquationEntity(target: try Expression(parsing: "T\\cos\\theta"))
        var reported: Bool?
        placeholder.onFill = { _, isMatch in reported = isMatch }
        let drop = placeholder.components[DropTargetComponent.self]!
        let result = drop.onDrop!(.expression(try Expression(parsing: "x + y")), Circle(radius: 0.1))
        #expect(result == .rejected)
        #expect(reported == false)
        #expect(!placeholder.isFilled)
    }

    @Test func placeholderWithoutTargetAcceptsAnything() {
        let placeholder = PlaceholderEquationEntity()
        let drop = placeholder.components[DropTargetComponent.self]!
        #expect(drop.onDrop!(.expression(.variable("q")), Circle(radius: 0.1)) == .accepted)
        // A projection payload isn't an expression — not accepted here.
        #expect(drop.accepts!(.projection(.x)) == false)
    }

    // MARK: measuredGlyphs (D6)

    @Test func parseVerticalAlignReadsSignedEx() {
        #expect(abs(MathSVG.parseVerticalAlignEx("vertical-align: -1.577ex;")! - (-1.577)) < tolerance)
        #expect(abs(MathSVG.parseVerticalAlignEx("vertical-align: 0.5ex;")! - 0.5) < tolerance)
        #expect(MathSVG.parseVerticalAlignEx("width: 2ex;") == nil)
    }

    @Test func measuredGlyphsAreBaselineRelative() throws {
        let svg = ##"<svg style="vertical-align: -0.5ex;" viewBox="0 -700 500 700"><defs><path id="g" d="M0 0L100 0L100 100Z"/></defs><g transform="scale(1,-1)"><use xlink:href="#g"/></g></svg>"##
        let measured = try MathSVG.measuredGlyphs(fromSVG: svg)
        #expect(measured.glyphs.count == 1)
        // baseline depth = -0.5 ex × 0.441 em/ex.
        #expect(abs(measured.baselineOffset - (-0.5 * 0.441)) < 1e-3)
        // Not bounds-centered: the glyph sits on the baseline (min.y ≈ 0).
        #expect(abs(measured.glyphs[0].path.bounds.min.y) < 1e-3)
    }

    // MARK: Font provider smoke

    @Test func fontProviderRendersTokenValue() throws {
        let candidates = [
            "/System/Library/Fonts/Supplemental/Arial.ttf",
            "/System/Library/Fonts/Supplemental/Tahoma.ttf",
        ]
        var font: Font?
        for path in candidates where FileManager.default.fileExists(atPath: path) {
            if let data = FileManager.default.contents(atPath: path), let f = try? Font(data: [UInt8](data)) {
                font = f
                break
            }
        }
        guard let font else { return }  // environment-dependent — skip
        let provider = FontTokenGlyphProvider(font: font)
        let run = provider.glyphs(for: DisplayToken(kind: .number, value: "12", tex: "12"))
        #expect(run.width > 0)
        #expect(!run.glyphs.isEmpty)
    }
}
