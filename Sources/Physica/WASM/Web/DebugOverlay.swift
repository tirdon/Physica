// Shift-held index overlay: absolutely-positioned DOM labels projected from
// entity centers (group children get dotted paths like "1.0").

#if os(WASI)
import JavaScriptKit

@MainActor
final class DebugOverlay {
    private let engine: Engine
    private let scene: Scene
    private let host: JSValue
    private let canvas: JSValue
    private var labelElements: [JSValue] = []

    init?(engine: Engine, scene: Scene, hostID: String, canvas: JSValue) {
        let host: JSValue = JSObject.global.document.getElementById(hostID)
        guard !host.isNull else { return nil }
        self.engine = engine
        self.scene = scene
        self.host = host
        self.canvas = canvas
    }

    func sync() {
        guard engine.isDebugOverlayActive else {
            if !labelElements.isEmpty { clear() }
            return
        }

        let labels = scene.collectDebugLabels()
        let document = JSObject.global.document
        let view = scene.camera.viewMatrix()
        let projection = scene.camera.projectionMatrix(aspect: scene.viewportAspect)
        let viewProjection = projection * view
        let width = canvas.clientWidth.number ?? 0
        let height = canvas.clientHeight.number ?? 0

        // Project first and drop labels outside the viewport — an entity that
        // keeps moving after leaving the frame (a body falling off the floor)
        // must not drag its label outside the canvas.
        let slack: Real = 1.02
        var placements: [(text: String, x: Double, y: Double)] = []
        placements.reserveCapacity(labels.count)
        for label in labels {
            let clip = viewProjection.transform(
                SIMD4(label.worldPosition.x, label.worldPosition.y, label.worldPosition.z, 1)
            )
            guard clip.w > 0 else { continue }   // behind the camera
            let ndcX = clip.x / clip.w
            let ndcY = clip.y / clip.w
            guard abs(ndcX) <= slack, abs(ndcY) <= slack else { continue }
            placements.append((
                text: label.text,
                x: (Double(ndcX) * 0.5 + 0.5) * width,
                y: (1 - (Double(ndcY) * 0.5 + 0.5)) * height
            ))
        }

        // Grow/shrink the element pool to match.
        while labelElements.count < placements.count {
            let element = document.createElement("div")
            element.className = "overlay-label"
            _ = host.appendChild(element)
            labelElements.append(element)
        }
        while labelElements.count > placements.count {
            let element = labelElements.removeLast()
            _ = element.remove()
        }

        for (index, placement) in placements.enumerated() {
            let element = labelElements[index]
            element.textContent = .string(placement.text)
            _ = element.style.setProperty("left", "\(Int(placement.x))px")
            _ = element.style.setProperty("top", "\(Int(placement.y))px")
        }
    }

    private func clear() {
        for element in labelElements {
            _ = element.remove()
        }
        labelElements.removeAll()
    }
}
#endif
