// DOM input → Physica input. Pointer events on the canvas (mouse, touch, and
// Apple Pencil all arrive through one unified API) plus the Shift key for the
// debug overlay.
//
// One gesture at a time: the first pointer down owns the scene until it lifts
// or the browser cancels it, so a second finger or a resting palm can't corrupt
// the single-pointer drag state machine. A pen preempts a finger that is
// already down (palm rejection — the Pencil is the precision instrument);
// every other newcomer is ignored. `pointercancel` aborts the gesture so a
// system takeover never strands a drag.

#if os(WASI)
import JavaScriptKit

@MainActor
final class InputBindings {
    private let engine: Engine
    private let scene: Scene
    private let canvas: JSValue
    private var closures: [JSClosure] = []

    /// `pointerId` of the gesture that currently owns the scene, and its device
    /// kind — nil between gestures.
    private var activePointerID: Double?
    private var activeKind: PointerKind = .mouse

    init(engine: Engine, scene: Scene, canvas: JSValue) {
        self.engine = engine
        self.scene = scene
        self.canvas = canvas

        listen(canvas, "pointerdown") { [weak self] event in self?.pointerDown(event) }
        listen(canvas, "pointermove") { [weak self] event in self?.pointerMove(event) }
        listen(canvas, "pointerup") { [weak self] event in self?.pointerUp(event) }
        listen(canvas, "pointercancel") { [weak self] event in self?.pointerCancel(event) }

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

    // MARK: Pointer gesture (single active pointer, pen-priority palm rejection)

    private func pointerDown(_ event: JSValue) {
        let id = pointerID(of: event)
        let kind = pointerKind(of: event)
        if let active = activePointerID, active != id {
            // Already mid-gesture. An Apple Pencil takes over from a resting
            // finger; every other newcomer (second finger, palm, mouse) waits
            // for the active pointer to lift.
            guard kind == .pen, activeKind == .touch else { return }
            scene.dispatch(.pointerCancelled, kind: .touch)
        }
        activePointerID = id
        activeKind = kind
        // Keep receiving move/up even if the pointer drifts off the canvas
        // (dragging a token past the edge). Auto-released on up/cancel.
        _ = canvas.setPointerCapture(event.pointerId)
        scene.dispatch(.pointerDown(worldPoint(event)), kind: kind, pressure: pressure(of: event))
    }

    private func pointerMove(_ event: JSValue) {
        guard isActive(event) else { return }
        scene.dispatch(.pointerMoved(worldPoint(event)), kind: activeKind, pressure: pressure(of: event))
    }

    private func pointerUp(_ event: JSValue) {
        guard isActive(event) else { return }
        scene.dispatch(.pointerUp(worldPoint(event)), kind: activeKind, pressure: pressure(of: event))
        endGesture()
    }

    private func pointerCancel(_ event: JSValue) {
        guard isActive(event) else { return }
        scene.dispatch(.pointerCancelled, kind: activeKind)
        endGesture()
    }

    private func endGesture() {
        activePointerID = nil
        activeKind = .mouse
    }

    private func isActive(_ event: JSValue) -> Bool {
        activePointerID != nil && pointerID(of: event) == activePointerID
    }

    // MARK: DOM → value helpers

    private func pointerID(of event: JSValue) -> Double {
        event.pointerId.number ?? -1
    }

    private func pointerKind(of event: JSValue) -> PointerKind {
        switch event.pointerType.string ?? "" {
        case "pen": return .pen
        case "touch": return .touch
        default: return .mouse
        }
    }

    private func pressure(of event: JSValue) -> Real {
        Real(event.pressure.number ?? 0)
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
