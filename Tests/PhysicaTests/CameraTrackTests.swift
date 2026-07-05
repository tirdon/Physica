import Testing
@testable import PhysicaFoundation
@testable import PhysicaAlgebra
@testable import PhysicaTypesetting
@testable import PhysicaKernel
@testable import PhysicaCharts
@testable import PhysicaPhysics
@testable import PhysicaEquationGame

@Suite @MainActor struct CameraTrackTests {
    private let tolerance: Real = 1e-4

    @Test func frameTransformWritesThroughToCamera() {
        let scene = Scene()
        scene.frame.position = Position(3, 2, 10)
        #expect(scene.camera.transform.position == Position(3, 2, 10))
        scene.camera.transform.position = Position(-1, 0, 10)
        #expect(abs(scene.frame.position.x + 1) < tolerance)
    }

    @Test func frameMoveAnimatesCameraPosition() {
        let scene = Scene()
        scene.play(scene.frame.move(to: Position(6, 0, 10)), for: 1.s)
        scene.update(deltaTime: 0.5)
        let mid = scene.camera.transform.position.x
        #expect(mid > 0 && mid < 6)
        scene.update(deltaTime: 0.6)
        #expect(abs(scene.camera.transform.position.x - 6) < tolerance)
    }

    @Test func frameZoomAnimatesEveryProjectionKind() {
        let scene = Scene()
        scene.camera.projection = .orthographicFit(extent: 10)
        scene.play(scene.frame.zoom(to: 5), for: 1.s)
        scene.update(deltaTime: 1.1)
        guard case .orthographicFit(let extent) = scene.camera.projection else {
            Issue.record("projection kind changed")
            return
        }
        #expect(abs(extent - 5) < tolerance)

        let heightScene = Scene()
        heightScene.camera.projection = .orthographic(height: 8)
        heightScene.play(heightScene.frame.zoom(by: 0.5), for: 1.s)
        heightScene.update(deltaTime: 1.1)
        guard case .orthographic(let height) = heightScene.camera.projection else {
            Issue.record("projection kind changed")
            return
        }
        #expect(abs(height - 4) < tolerance)

        let fovScene = Scene()
        fovScene.camera.projection = .perspective(fovYDegrees: 60)
        fovScene.play(fovScene.frame.zoom(to: 30), for: 1.s)
        fovScene.update(deltaTime: 1.1)
        guard case .perspective(let fov) = fovScene.camera.projection else {
            Issue.record("projection kind changed")
            return
        }
        #expect(abs(fov - 30) < tolerance)
    }

    @Test func scrubBackwardRestoresCameraExactly() {
        let scene = Scene()
        let before = scene.camera.transform.position
        scene.play(scene.frame.move(to: Position(6, 2, 10)), scene.frame.zoom(to: 4), for: 1.s)
        scene.seek(to: 1)
        #expect(abs(scene.camera.transform.position.x - 6) < tolerance)
        #expect(abs(scene.frame.zoomExtent - 4) < tolerance)
        scene.seek(to: 0)
        // Strictly-before semantics: t = 0 is the clip's begin, value at start.
        #expect(scene.camera.transform.position == before)
        #expect(abs(scene.frame.zoomExtent - 10) < tolerance)
        // Forward again lands exactly on the endpoint.
        scene.seek(to: 1)
        #expect(abs(scene.camera.transform.position.x - 6) < tolerance)
    }

    @Test func frameBoundsReflectsAnimatedCameraMidClip() {
        let scene = Scene()
        scene.viewportAspect = 1.6
        scene.play(scene.frame.move(to: Position(10, 0, 10)), for: 1.s)
        scene.update(deltaTime: 0.5)
        // The visible frame follows the camera, so unit-move resolution and
        // pointer mapping stay correct mid-transition.
        #expect(abs(scene.frameBounds.center.x - scene.camera.transform.position.x) < tolerance)
    }

    @Test func focusOnEntityResolvesAtClipBegin() {
        let scene = Scene()
        scene.viewportAspect = 1.6
        let box = Rectangle(width: 2, height: 1)
        box.position = Position(4, 1, 0)
        scene.add(box)
        scene.play(scene.frame.focus(on: box, margin: 1.5), for: 1.s)
        scene.update(deltaTime: 1.1)
        #expect(abs(scene.camera.transform.position.x - 4) < 0.01)
        #expect(abs(scene.camera.transform.position.y - 1) < 0.01)
        // z preserved.
        #expect(abs(scene.camera.transform.position.z - 10) < tolerance)
        // Fit: needs 3 wide × 1.5 high at aspect 1.6 → extent max(3, 1.5·1.6) = 3.
        #expect(abs(scene.frame.zoomExtent - 3) < 0.01)
    }

    @Test func frameResetReturnsToDefaultFramingAndScrubsBack() {
        let scene = Scene()
        // Push the camera off the default framing, then reset it home.
        scene.play(scene.frame.shift(Position(0.4, 0.2, 0)), scene.frame.zoom(to: 7.5), for: 1.s)
        scene.reset(for: 1.s)
        scene.seek(to: 2)
        #expect(abs(scene.camera.transform.position.x) < tolerance)
        #expect(abs(scene.camera.transform.position.y) < tolerance)
        #expect(abs(scene.camera.transform.position.z - 10) < tolerance)
        #expect(abs(scene.frame.zoomExtent - 10) < tolerance)
        // Scrub back to the pushed-in framing: the reset clip is scrub-safe.
        scene.seek(to: 1)
        #expect(abs(scene.camera.transform.position.x - 0.4) < tolerance)
        #expect(abs(scene.frame.zoomExtent - 7.5) < tolerance)
    }

    @Test func saveStateRoundTripsOnFrame() {
        let scene = Scene()
        scene.play(scene.frame.saveState())
        scene.play(scene.frame.move(to: Position(5, 5, 10)), for: 1.s)
        scene.play(scene.frame.restoreState(), for: 1.s)
        scene.seek(to: 1)
        #expect(abs(scene.camera.transform.position.x - 5) < tolerance)
        scene.seek(to: 2)
        #expect(abs(scene.camera.transform.position.x) < tolerance)
        #expect(abs(scene.camera.transform.position.y) < tolerance)
    }

    @Test func zoomExtentFitMathPerProjection() {
        let bounds = Bounds(center: Position(0, 0, 0), size: Position(4, 2, 0))
        // fit: width-limited at wide aspect.
        let fit = FocusZoomBlueprint.extent(
            fitting: bounds, margin: 1, projection: .orthographicFit(extent: 10), cameraZ: 10, aspect: 1.6
        )
        #expect(abs(fit - 4) < tolerance)
        // orthographic: height = max(2, 4/1.6) = 2.5.
        let ortho = FocusZoomBlueprint.extent(
            fitting: bounds, margin: 1, projection: .orthographic(height: 6), cameraZ: 10, aspect: 1.6
        )
        #expect(abs(ortho - 2.5) < tolerance)
        // perspective: 2·atan(1.25/10) ≈ 14.25°.
        let fov = FocusZoomBlueprint.extent(
            fitting: bounds, margin: 1, projection: .perspective(fovYDegrees: 60), cameraZ: 10, aspect: 1.6
        )
        #expect(abs(fov - 2 * Real.atan2(1.25, 10) * 180 / .pi) < tolerance)
    }
}
