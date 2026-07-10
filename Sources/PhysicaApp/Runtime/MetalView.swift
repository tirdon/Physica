// MetalView — the MTKView subclass that forwards AppKit input to the scene, the
// native counterpart of the web `InputBindings`. Mouse events become
// `scene.dispatch(.pointerDown/.pointerMoved/.pointerUp(worldPos))`; a
// double-click also emits `.doubleClick`; idle `mouseMoved` drives
// HoverComponents and `mouseExited` clears the hover. Space toggles
// play/pause, arrows seek ∓/± a small step (PlaybackControls' semantics), and
// Shift / Option+Shift recompute the debug-overlay flags on every modifier
// change (mirroring `InputBindings.syncOverlayModifiers`).

import PhysicaFoundation
import PhysicaKernel

#if os(macOS)
import AppKit
import MetalKit

@MainActor
final class MetalView: MTKView {
    weak var boundEngine: Engine?
    weak var boundScene: Scene?
    private var trackingArea: NSTrackingArea?

    /// Small seek step for the arrow keys (seconds).
    private let seekStep: Real = 0.25

    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    // MARK: Pointer

    override func mouseDown(with event: NSEvent) {
        boundScene?.dispatch(.pointerDown(world(event)), kind: .mouse)
    }

    override func mouseDragged(with event: NSEvent) {
        boundScene?.dispatch(.pointerMoved(world(event)), kind: .mouse)
    }

    override func mouseUp(with event: NSEvent) {
        let point = world(event)
        boundScene?.dispatch(.pointerUp(point), kind: .mouse)
        // The single-click tap fired on this up; a double emits doubleClick next
        // (DOM order), driving DoubleTapComponent.
        if event.clickCount == 2 { boundScene?.dispatch(.doubleClick(point)) }
    }

    override func mouseMoved(with event: NSEvent) {
        // Idle bare-pointer move: hover tracking (mouse only, like the web shell).
        boundScene?.dispatch(.pointerMoved(world(event)), kind: .mouse)
    }

    override func mouseExited(with event: NSEvent) {
        boundScene?.drag.clearHover()
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) { handleKey(event, isDown: true) }
    override func keyUp(with event: NSEvent) { handleKey(event, isDown: false) }

    override func flagsChanged(with event: NSEvent) {
        syncOverlayModifiers(event.modifierFlags)
    }

    private func handleKey(_ event: NSEvent, isDown: Bool) {
        guard let scene = boundScene else { return }
        let key = event.charactersIgnoringModifiers ?? ""
        scene.dispatch(isDown ? .keyDown(key) : .keyUp(key))
        guard isDown else { return }
        switch event.keyCode {
        case 49: togglePlayback(scene)   // space
        case 123: seek(scene, by: -seekStep)   // left arrow
        case 124: seek(scene, by: seekStep)    // right arrow
        default: break
        }
    }

    /// Mirrors PlaybackControls: replay at end, resume if paused, else pause.
    private func togglePlayback(_ scene: Scene) {
        let state = scene.timeline.state
        if state.duration > 0, state.currentTime >= state.duration - 1e-6 {
            scene.seek(to: 0)
            scene.resume()
        } else if scene.timeline.isPaused {
            scene.resume()
        } else {
            scene.timeline.setPaused(true)
        }
    }

    private func seek(_ scene: Scene, by delta: Real) {
        let target = scene.timeline.currentTime + delta
        scene.seek(to: max(0, min(target, scene.timeline.duration)))
    }

    /// Shift → index overlay; Option+Shift → the interactive overlay. Recomputed
    /// from live flags so the modes hand off as Option is pressed/released under
    /// Shift — exactly like `InputBindings.syncOverlayModifiers`.
    private func syncOverlayModifiers(_ flags: NSEvent.ModifierFlags) {
        guard let engine = boundEngine, let scene = boundScene else { return }
        let shift = flags.contains(.shift)
        let alt = flags.contains(.option)
        engine.isInteractiveOverlayActive = shift && alt
        engine.isDebugOverlayActive = shift && !alt
        scene.dispatch(shift ? .keyDown("Shift") : .keyUp("Shift"))
    }

    // MARK: View point → world

    private func world(_ event: NSEvent) -> Position {
        let point = convert(event.locationInWindow, from: nil)
        let width = max(bounds.width, 1)
        let height = max(bounds.height, 1)
        // AppKit is bottom-left origin; the scene expects normalized top-left.
        let normalized = SIMD2(Real(point.x / width), Real(1 - point.y / height))
        return boundScene?.worldPosition(normalizedViewport: normalized) ?? .zero
    }
}
#endif
