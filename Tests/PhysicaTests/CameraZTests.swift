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

// Phase-4c pin: `scene.frame.move(to:)` preserves the camera's z by default
// (an absolute recenter must not dolly the camera onto the z = 0 stage);
// `keepingZ: false` honors the destination's z exactly.

@Suite @MainActor
struct CameraZTests {
    @Test func frameMovePreservesCameraZ() {
        let scene = Scene()
        let zBefore = scene.camera.transform.position.z
        #expect(zBefore != 0)  // the default camera sits off the stage plane

        scene.play(scene.frame.move(to: Position(6, 1, 0)), for: 1.s)
        scene.update(deltaTime: 0.016)
        scene.seek(to: 1.0)

        let position = scene.camera.transform.position
        #expect(approx(position, Position(6, 1, zBefore), tolerance: 1e-4))
    }

    @Test func keepingZFalseHonorsDestinationZ() {
        let scene = Scene()
        scene.play(scene.frame.move(to: Position(0, 0, 4), keepingZ: false), for: 1.s)
        scene.update(deltaTime: 0.016)
        scene.seek(to: 1.0)

        #expect(approx(scene.camera.transform.position, Position(0, 0, 4), tolerance: 1e-4))
    }

    @Test func frameShiftStillMovesAllAxes() {
        let scene = Scene()
        let before = scene.camera.transform.position
        scene.play(scene.frame.shift(Position(1, 0, -2)), for: 1.s)
        scene.update(deltaTime: 0.016)
        scene.seek(to: 1.0)

        #expect(approx(scene.camera.transform.position, before + Position(1, 0, -2), tolerance: 1e-4))
    }
}
