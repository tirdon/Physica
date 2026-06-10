// App — browser boot: renderer + engine + demo scene + frame loop.

#if os(WASI)
import JavaScriptKit
import Physica

@MainActor
enum App {
    static var engine: Engine?
    static var renderer: WebGPURenderer?
    static var rafDriver: RAFDriver?
    static var controls: PlaybackControls?
    static var inputBindings: InputBindings?
    static var visibilityObserver: VisibilityObserver?
    static var overlay: DebugOverlay?

    static func boot() async {
        let console = JSObject.global.console

        // Fonts come over the network; the scene must still build without one.
        let font: Font?
        do {
            font = try await FontLoader.load()
        } catch {
            font = nil
            _ = console.warn("Physica: font unavailable —", String(describing: error))
        }

        // Build the scene script first — it must work without a GPU (headless smoke).
        let engine = Engine()
        let scene = engine.makeScene(name: "pendulum") { scene in
            PendulumDemo.build(scene, font: font)
        }
        self.engine = engine
        _ = console.log("Physica: scene ready\n" + scene.timeline.debugString)

        do {
            let renderer = try await WebGPURenderer.create(canvasID: "main")
            engine.bind(renderer, to: scene)

            let canvas: JSValue = JSObject.global.document.getElementById("main")
            self.controls = PlaybackControls(scene: scene)
            self.inputBindings = InputBindings(engine: engine, scene: scene, canvas: canvas)
            self.visibilityObserver = VisibilityObserver(
                engine: engine, canvas: canvas, sceneID: scene.id
            )
            self.overlay = DebugOverlay(
                engine: engine, scene: scene, hostID: "scene-host", canvas: canvas
            )

            let driver = RAFDriver()
            driver.start { deltaTime in
                engine.tick(deltaTime: deltaTime)
                App.controls?.sync()
                App.overlay?.sync()
            }

            self.renderer = renderer
            self.rafDriver = driver
            _ = console.log("Physica: WebGPU renderer running")
        } catch {
            _ = console.error("Physica: renderer unavailable —", String(describing: error))
        }
    }
}
#endif
