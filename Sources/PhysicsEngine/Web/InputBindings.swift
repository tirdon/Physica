// DOM input → Physica input: pointer events on the canvas (world coordinates)
// and the Shift key for the debug overlay.

#if os(WASI)
import JavaScriptKit
import Physica

@MainActor
final class InputBindings {
    private let engine: Engine
    private let scene: Scene
    private let canvas: JSValue
    private var closures: [JSClosure] = []

    init(engine: Engine, scene: Scene, canvas: JSValue) {
        self.engine = engine
        self.scene = scene
        self.canvas = canvas

        listen(canvas, "pointerdown") { [weak self] event in
            guard let self else { return }
            _ = self.canvas.setPointerCapture(event.pointerId)
            self.scene.dispatch(.pointerDown(self.worldPoint(event)))
        }
        listen(canvas, "pointermove") { [weak self] event in
            guard let self else { return }
            self.scene.dispatch(.pointerMoved(self.worldPoint(event)))
        }
        listen(canvas, "pointerup") { [weak self] event in
            guard let self else { return }
            self.scene.dispatch(.pointerUp(self.worldPoint(event)))
        }

        let window = JSObject.global.jsValue
        listen(window, "keydown") { [weak self] event in
            guard let self, event.key.string == "Shift" else { return }
            self.engine.isDebugOverlayActive = true
            self.scene.dispatch(.keyDown("Shift"))
        }
        listen(window, "keyup") { [weak self] event in
            guard let self, event.key.string == "Shift" else { return }
            self.engine.isDebugOverlayActive = false
            self.scene.dispatch(.keyUp("Shift"))
        }
    }

    private func worldPoint(_ event: JSValue) -> Position {
        let rect = canvas.getBoundingClientRect()
        let width = rect.width.number ?? 1
        let height = rect.height.number ?? 1
        let x = ((event.clientX.number ?? 0) - (rect.left.number ?? 0)) / max(width, 1)
        let y = ((event.clientY.number ?? 0) - (rect.top.number ?? 0)) / max(height, 1)
        return scene.worldPosition(normalizedViewport: SIMD2(Real(x), Real(y)))
    }

    private func listen(_ element: JSValue, _ event: String, _ handler: @escaping @MainActor (JSValue) -> Void) {
        let closure = JSClosure { arguments in
            let event = arguments.first ?? .undefined
            MainActor.assumeIsolated {
                handler(event)
            }
            return .undefined
        }
        closures.append(closure)
        _ = element.addEventListener(event, closure)
    }
}
#endif
