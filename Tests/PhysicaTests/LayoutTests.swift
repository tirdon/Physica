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

@Suite @MainActor
struct LayoutTests {
    @Test func rowArrangesHorizontally() {
        let scene = Scene()
        let a = Rectangle(width: 1, height: 1)
        let b = Rectangle(width: 2, height: 1)
        let row = Row(a, b)
        row.spacing = 0.5
        scene.add(row)
        scene.update(deltaTime: 0.016)

        // total = 1 + 0.5 + 2 = 3.5, centered → a at -1.25, b at 0.75
        #expect(approx(a.position.x, -1.25))
        #expect(approx(b.position.x, 0.75))
        #expect(approx(a.position.y, 0))
        #expect(approx(row.localBounds.size.x, 3.5))
    }

    @Test func rowAlignment() {
        let scene = Scene()
        let small = Rectangle(width: 1, height: 1)
        let tall = Rectangle(width: 1, height: 3)
        let row = Row(small, tall)
        row.alignment = .top
        scene.add(row)
        scene.update(deltaTime: 0.016)

        // tops align at +1.5
        #expect(approx(small.position.y, 1.5 - 0.5))
        #expect(approx(tall.position.y, 0))
    }

    @Test func columnArrangesVertically() {
        let scene = Scene()
        let a = Rectangle(width: 1, height: 1)
        let b = Rectangle(width: 1, height: 2)
        let column = Column(a, b)
        column.spacing = 1
        scene.add(column)
        scene.update(deltaTime: 0.016)

        // total = 1 + 1 + 2 = 4 → a center at 1.5, b at -1
        #expect(approx(a.position.y, 1.5))
        #expect(approx(b.position.y, -1))
        #expect(approx(a.position.x, 0))
    }

    @Test func gridPlacesRowMajor() {
        let scene = Scene()
        let cells = (0..<4).map { _ in Rectangle(width: 1, height: 1) }
        let grid = Grid(columns: 2, cells[0], cells[1], cells[2], cells[3])
        grid.spacing = 1
        scene.add(grid)
        scene.update(deltaTime: 0.016)

        #expect(approx(cells[0].position, Position(-1, 1, 0)))
        #expect(approx(cells[1].position, Position(1, 1, 0)))
        #expect(approx(cells[2].position, Position(-1, -1, 0)))
        #expect(approx(cells[3].position, Position(1, -1, 0)))
    }

    @Test func didSetInvalidationRelayouts() {
        let scene = Scene()
        let a = Rectangle(width: 1, height: 1)
        let b = Rectangle(width: 1, height: 1)
        let row = Row(a, b)
        scene.add(row)
        scene.update(deltaTime: 0.016)
        let before = a.position.x

        row.spacing = 2  // didSet → invalidate → next frame re-layout
        scene.update(deltaTime: 0.016)
        #expect(a.position.x < before)
        #expect(approx(a.position.x, -1.5))

        row.addChild(Rectangle(width: 1, height: 1))  // childrenDidChange
        scene.update(deltaTime: 0.016)
        #expect(approx(a.position.x, -3))
    }

    @Test func layoutGroupMovesAsAWhole() {
        let scene = Scene()
        let row = Row(Circle(radius: 0.5), Circle(radius: 0.5))
        scene.add(row)
        scene.play(row.move(to: Position(0, 2, 0)), for: 1.s)
        scene.update(deltaTime: 1.5)

        #expect(approx(row.position.y, 2))
        // children keep their layout-local x, world positions inherit the shift
        #expect(approx(row.children[0].worldTransform.position.y, 2))
    }
}
