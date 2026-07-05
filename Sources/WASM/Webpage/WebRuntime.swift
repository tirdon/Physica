// One-call browser bootstrap: logs the timeline (GPU-free smoke relies on it),
// then wires WebGPU renderer + playback controls + input + visibility observer
// + debug overlay + the rAF loop around a scene. Apps keep the returned
// runtime alive and stay a few lines long.

import PhysicaMath
import PhysicaAlgebra
import PhysicaGeometry
import PhysicaTypesetting
import PhysicaKernel
import PhysicaPlotting
import PhysicaStory
import PhysicaPhysics
import PhysicaEquationGame

#if os(WASI)
import JavaScriptKit

@MainActor
public final class WebRuntime {
    public let engine: Engine
    private(set) var renderer: WebGPURenderer?
    private var rafDriver: RAFDriver?
    private var controls: PlaybackControls?
    private var inputBindings: InputBindings?
    private var visibilityObserver: VisibilityObserver?
    private var overlay: DebugOverlay?

    private init(engine: Engine) {
        self.engine = engine
    }

    /// Presents `scene` in the browser shell. Logs the scene/timeline first so
    /// headless (no-GPU) runs still print it; a missing renderer is reported,
    /// not fatal.
    @discardableResult
    public static func run(
        engine: Engine,
        scene: Scene,
        canvasID: String = "main",
        overlayHostID: String = "scene-host"
    ) async -> WebRuntime {
        let console = JSObject.global.console
        _ = console.log("Physica: scene ready\n" + scene.timeline.debugString)

        let runtime = WebRuntime(engine: engine)
        do {
            let renderer = try await WebGPURenderer.create(canvasID: canvasID)
            engine.bind(renderer, to: scene)
            _ = console.log(
                "Physica: scene size", Double(scene.size.x), "×", Double(scene.size.y)
            )

            let canvas: JSValue = JSObject.global.document.getElementById(canvasID)
            runtime.controls = PlaybackControls(scene: scene)
            runtime.inputBindings = InputBindings(engine: engine, scene: scene, canvas: canvas)
            runtime.visibilityObserver = VisibilityObserver(
                engine: engine, canvas: canvas, sceneID: scene.id
            )
            runtime.overlay = DebugOverlay(
                engine: engine, scene: scene, hostID: overlayHostID, canvas: canvas
            )

            let driver = RAFDriver()
            driver.start { [weak runtime] deltaTime in
                engine.tick(deltaTime: deltaTime)
                runtime?.controls?.sync()
                runtime?.overlay?.sync()
            }

            runtime.renderer = renderer
            runtime.rafDriver = driver
            _ = console.log("Physica: WebGPU renderer running")
        } catch {
            _ = console.error("Physica: renderer unavailable —", String(describing: error))
        }
        return runtime
    }
}
#endif
