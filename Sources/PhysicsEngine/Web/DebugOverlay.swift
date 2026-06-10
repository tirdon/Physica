// Shift-held index overlay: absolutely-positioned DOM labels projected from
// entity centers (group children get dotted paths like "1.0").

#if os(WASI)
import JavaScriptKit
import Physica

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

        // Grow/shrink the element pool to match.
        while labelElements.count < labels.count {
            let element = document.createElement("div")
            element.className = "overlay-label"
            _ = host.appendChild(element)
            labelElements.append(element)
        }
        while labelElements.count > labels.count {
            let element = labelElements.removeLast()
            _ = element.remove()
        }

        for (index, label) in labels.enumerated() {
            let clip = viewProjection.transform(
                SIMD4(label.worldPosition.x, label.worldPosition.y, label.worldPosition.z, 1)
            )
            let w = clip.w == 0 ? 1 : clip.w
            let x = (Double(clip.x / w) * 0.5 + 0.5) * width
            let y = (1 - (Double(clip.y / w) * 0.5 + 0.5)) * height
            let element = labelElements[index]
            element.textContent = .string(label.text)
            _ = element.style.setProperty("left", "\(Int(x))px")
            _ = element.style.setProperty("top", "\(Int(y))px")
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
