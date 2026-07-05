import Testing
@testable import PhysicaFoundation
@testable import PhysicaAlgebra
@testable import PhysicaTypesetting
@testable import PhysicaKernel
@testable import PhysicaCharts
@testable import PhysicaPhysics
@testable import PhysicaEquationGame

@Suite @MainActor struct InputTests {
    private let tolerance: Real = 1e-4

    @Test func dispatchRecordsDeviceKindAndPressure() {
        let scene = Scene()
        // Defaults read as a mouse with no pressure.
        #expect(scene.pointer.kind == .mouse)
        #expect(scene.pointer.pressure == 0)

        scene.dispatch(.pointerDown(.zero), kind: .pen, pressure: 0.7)
        #expect(scene.pointer.kind == .pen)
        #expect(scene.pointer.isDown)
        #expect(abs(scene.pointer.pressure - 0.7) < tolerance)

        scene.dispatch(.pointerMoved(Position(0.2, 0, 0)), kind: .pen, pressure: 0.4)
        #expect(abs(scene.pointer.pressure - 0.4) < tolerance)

        // Lifting clears pressure but remembers the device kind.
        scene.dispatch(.pointerUp(Position(0.2, 0, 0)), kind: .pen, pressure: 0)
        #expect(!scene.pointer.isDown)
        #expect(scene.pointer.pressure == 0)
        #expect(scene.pointer.kind == .pen)
    }

    @Test func bareDispatchStaysMouse() {
        let scene = Scene()
        // Host tests / desktop use the positional dispatch and stay `.mouse`.
        scene.dispatch(.pointerDown(.zero))
        #expect(scene.pointer.kind == .mouse)
        #expect(scene.pointer.isDown)
    }

    @Test func cancelClearsPressureAndButton() {
        let scene = Scene()
        scene.dispatch(.pointerDown(.zero), kind: .touch, pressure: 1)
        #expect(scene.pointer.isDown)

        scene.dispatch(.pointerCancelled, kind: .touch)
        #expect(!scene.pointer.isDown)
        #expect(scene.pointer.pressure == 0)
    }
}
