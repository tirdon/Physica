// Shift-held index overlay: absolutely-positioned DOM labels projected from
// entity centers — one number per top-level entity (groups collapse, they
// don't unfold into "1.0" children). Option+Shift swaps in the interactive
// overlay (draggable/touchable entities, numbered and colored by kind) and
// additionally outlines every drop target's hit region as a rectangle, so the
// user sees where a token lands, not just that an entity accepts drops.

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
final class DebugOverlay {
    private let engine: Engine
    private let scene: Scene
    private let host: JSValue
    private let canvas: JSValue
    private var labelElements: [JSValue] = []
    /// Drop-area outline rectangles, pooled separately from the labels — only
    /// populated while the Option+Shift interactive overlay is active.
    private var areaElements: [JSValue] = []

    init?(engine: Engine, scene: Scene, hostID: String, canvas: JSValue) {
        let host: JSValue = JSObject.global.document.getElementById(hostID)
        guard !host.isNull else { return nil }
        self.engine = engine
        self.scene = scene
        self.host = host
        self.canvas = canvas
    }

    func sync() {
        // Option+Shift → only interactive (draggable/touchable) entities; plain
        // Shift → every index. Neither held → tear the labels down.
        let interactive = engine.isInteractiveOverlayActive
        let labels: [DebugLabel]
        if interactive {
            labels = scene.collectInteractiveDebugLabels()
        } else if engine.isDebugOverlayActive {
            labels = scene.collectDebugLabels()
        } else {
            if !labelElements.isEmpty || !areaElements.isEmpty { clear() }
            return
        }

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
        var placements: [(text: String, css: String, x: Double, y: Double)] = []
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
                css: cssClass(for: label),
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
            // Pooled elements switch modes/kinds, so re-stamp the class each frame.
            element.className = .string(placement.css)
            element.textContent = .string(placement.text)
            _ = element.style.setProperty("left", "\(Int(placement.x))px")
            _ = element.style.setProperty("top", "\(Int(placement.y))px")
        }

        syncDropAreas(interactive: interactive, viewProjection: viewProjection,
                      width: width, height: height, document: document)
    }

    /// Outline each drop target's projected bounds (Option+Shift only). The box
    /// corners project to NDC; we take the screen-space AABB so a rotated target
    /// still gets a tight axis-aligned outline. Empty (`!interactive`) tears the
    /// rectangles down via the shrink loop.
    private func syncDropAreas(
        interactive: Bool, viewProjection: Matrix4,
        width: Double, height: Double, document: JSValue
    ) {
        var rects: [(x: Double, y: Double, w: Double, h: Double)] = []
        if interactive {
            for bounds in scene.collectDropAreas() {
                var minX = Double.infinity, minY = Double.infinity
                var maxX = -Double.infinity, maxY = -Double.infinity
                var anyVisible = false
                for corner in bounds.corners {
                    let clip = viewProjection.transform(SIMD4(corner.x, corner.y, corner.z, 1))
                    guard clip.w > 0 else { continue }   // behind the camera
                    anyVisible = true
                    let sx = (Double(clip.x / clip.w) * 0.5 + 0.5) * width
                    let sy = (1 - (Double(clip.y / clip.w) * 0.5 + 0.5)) * height
                    minX = Swift.min(minX, sx); maxX = Swift.max(maxX, sx)
                    minY = Swift.min(minY, sy); maxY = Swift.max(maxY, sy)
                }
                // Drop boxes scrolled wholly off-canvas earn no outline.
                guard anyVisible, maxX >= 0, minX <= width, maxY >= 0, minY <= height
                else { continue }
                rects.append((x: minX, y: minY, w: maxX - minX, h: maxY - minY))
            }
        }

        while areaElements.count < rects.count {
            let element = document.createElement("div")
            element.className = "overlay-drop-area"
            _ = host.appendChild(element)
            areaElements.append(element)
        }
        while areaElements.count > rects.count {
            let element = areaElements.removeLast()
            _ = element.remove()
        }
        for (index, rect) in rects.enumerated() {
            let element = areaElements[index]
            _ = element.style.setProperty("left", "\(Int(rect.x))px")
            _ = element.style.setProperty("top", "\(Int(rect.y))px")
            _ = element.style.setProperty("width", "\(Int(rect.w))px")
            _ = element.style.setProperty("height", "\(Int(rect.h))px")
        }
    }

    /// Plain index labels keep `overlay-label`; interactive labels add a
    /// per-kind modifier (`overlay-label-drag`, `-drop`, …) the stylesheet
    /// colors, so the kind reads as color instead of text.
    private func cssClass(for label: DebugLabel) -> String {
        guard let kind = label.interaction else { return "overlay-label" }
        return "overlay-label overlay-label-\(kind.rawValue)"
    }

    private func clear() {
        for element in labelElements {
            _ = element.remove()
        }
        labelElements.removeAll()
        for element in areaElements {
            _ = element.remove()
        }
        areaElements.removeAll()
    }
}
#endif
