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
        // The browser does the double-click timing; we forward the debounced
        // event (a MouseEvent — clientX/Y present, no pointerId/pointerType).
        listen(canvas, "dblclick") { [weak self] event in self?.doubleClick(event) }
        // Bare cursor left the canvas — drop any standing hover (idle only; a
        // captured drag keeps receiving moves off-canvas).
        listen(canvas, "pointerleave") { [weak self] _ in self?.pointerLeave() }

        let window = JSObject.global.jsValue
        listen(window, "keydown") { [weak self] event in self?.syncOverlayModifiers(event, isUp: false) }
        listen(window, "keyup") { [weak self] event in self?.syncOverlayModifiers(event, isUp: true) }
    }

    /// Shift → index overlay; Option+Shift → the interactive (draggable /
    /// touchable) overlay. Recomputed from the live modifier flags on every key
    /// event so the two modes hand off cleanly as Option is pressed or released
    /// while Shift stays down.
    private func syncOverlayModifiers(_ event: JSValue, isUp: Bool) {
        let shift = event.shiftKey.boolean ?? false
        let alt = event.altKey.boolean ?? false
        engine.isInteractiveOverlayActive = shift && alt
        engine.isDebugOverlayActive = shift && !alt
        if event.key.string == "Shift" {
            scene.dispatch(isUp ? .keyUp("Shift") : .keyDown("Shift"))
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
        if isActive(event) {
            scene.dispatch(.pointerMoved(worldPoint(event)), kind: activeKind, pressure: pressure(of: event))
        } else if activePointerID == nil {
            // No gesture in flight: forward as a bare hover move so
            // HoverComponents track the cursor. A non-active pointer *during* a
            // gesture (second finger, palm) stays ignored. Touch/pen emit no
            // moves while up, so this is the mouse-hover path in practice.
            scene.dispatch(.pointerMoved(worldPoint(event)), kind: pointerKind(of: event))
        }
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

    private func doubleClick(_ event: JSValue) {
        scene.dispatch(.doubleClick(worldPoint(event)))
    }

    private func pointerLeave() {
        guard activePointerID == nil else { return }
        scene.drag.clearHover()
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
