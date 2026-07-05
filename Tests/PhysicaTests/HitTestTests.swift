import Testing
@testable import PhysicaFoundation
@testable import PhysicaAlgebra
@testable import PhysicaTypesetting
@testable import PhysicaKernel
@testable import PhysicaCharts
@testable import PhysicaPhysics
@testable import PhysicaEquationGame

@Suite @MainActor struct HitTestTests {
    @Test func picksLastPaintedOnOverlap() {
        let scene = Scene()
        let under = Circle(radius: 1)
        under.position = Position(0, 0, 0)
        let over = Rectangle(width: 2, height: 2)
        over.position = Position(0, 0, 0)
        scene.insert(under)
        scene.insert(over)   // painted later → wins the overlap
        #expect(scene.hitTest(worldXY: Position(0, 0, 0)) === over)
    }

    @Test func hitTestAllReturnsOverlapStackInPainterOrder() {
        let scene = Scene()
        let under = Circle(radius: 1)
        under.position = Position(0, 0, 0)
        let over = Rectangle(width: 2, height: 2)
        over.position = Position(0, 0, 0)
        scene.insert(under)
        scene.insert(over)   // painted later → last in the stack
        let stack = scene.hitTestAll(worldXY: Position(0, 0, 0))
        #expect(stack.count == 2)
        #expect(stack.first === under)   // painter order: bottom first
        #expect(stack.last === over)     // …topmost last (what hitTest returns)
        #expect(scene.hitTest(worldXY: Position(0, 0, 0)) === stack.last)
    }

    @Test func hitTestAllExcludesNonOverlapping() {
        let scene = Scene()
        let here = Circle(radius: 0.5)
        here.position = Position(0, 0, 0)
        let away = Circle(radius: 0.5)
        away.position = Position(4, 0, 0)
        scene.insert(here)
        scene.insert(away)
        let stack = scene.hitTestAll(worldXY: Position(0, 0, 0))
        #expect(stack.count == 1)
        #expect(stack.first === here)
        #expect(scene.hitTestAll(worldXY: Position(9, 9, 0)).isEmpty)
    }

    @Test func missesOutsideBounds() {
        let scene = Scene()
        let dot = Circle(radius: 0.5)
        dot.position = Position(0, 0, 0)
        scene.insert(dot)
        #expect(scene.hitTest(worldXY: Position(5, 5, 0)) == nil)
    }

    @Test func picksByPositionAmongSeparated() {
        let scene = Scene()
        let left = Circle(radius: 0.5)
        left.position = Position(-3, 0, 0)
        let right = Circle(radius: 0.5)
        right.position = Position(3, 0, 0)
        scene.insert(left)
        scene.insert(right)
        #expect(scene.hitTest(worldXY: Position(-3, 0, 0)) === left)
        #expect(scene.hitTest(worldXY: Position(3, 0, 0)) === right)
    }

    @Test func viewportPositionInvertsWorldPosition() {
        let scene = Scene()
        scene.viewportAspect = 1.6
        let world = scene.worldPosition(normalizedViewport: SIMD2(0.3, 0.7))
        let back = scene.viewportPosition(world: world)
        #expect(abs(back.x - 0.3) < 1e-4)
        #expect(abs(back.y - 0.7) < 1e-4)
    }
}
