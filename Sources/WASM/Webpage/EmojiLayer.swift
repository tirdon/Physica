// EmojiLayer — the DOM overlay that draws image glyphs (emoji): a
// pointer-transparent layer over the canvas holding one absolutely-positioned
// span per visible `ImagePrimitive`, projected with the same view-projection
// the renderer draws with (the DebugOverlay recipe). The browser rasterizes
// native color emoji — no glyph atlas, no texture pipeline — and the write
// fade rides the primitive's resolved opacity. Spans are pooled and re-styled
// per frame; extras hide.

import PhysicaFoundation
import PhysicaAlgebra
import PhysicaTypesetting
import PhysicaKernel
import PhysicaCharts
import PhysicaPhysics
import PhysicaEquationGame

#if os(WASI)
import JavaScriptKit

@MainActor
final class EmojiLayer {
    private var layer: JSValue
    private let canvas: JSValue
    private var spans: [JSValue] = []
    private var visible = 0

    /// Fails without a DOM or the scene host (headless smoke).
    init?(canvas: JSValue, hostID: String = "scene-host") {
        guard let dom = JSObject.global.document.object else { return nil }
        var host = dom.getElementById!(hostID)
        guard host.object != nil else { return nil }
        var layer = dom.createElement!("div")
        layer.className = .string("emoji-layer")
        _ = layer.setAttribute(
            "style", "position:absolute; inset:0; overflow:hidden; pointer-events:none;"
        )
        _ = host.appendChild(layer)
        self.layer = layer
        self.canvas = canvas
    }

    /// Projects and lays the snapshot's image glyphs; called by the renderer
    /// each frame with the view-projection it just drew with.
    func sync(_ snapshot: SceneSnapshot, viewProjection: Matrix4) {
        let rect = canvas.getBoundingClientRect()
        let width = rect.width.number ?? 0
        let height = rect.height.number ?? 0
        guard width > 0, height > 0, let dom = JSObject.global.document.object else { return }

        var used = 0
        for primitive in snapshot.primitives {
            guard case .image(let image) = primitive, image.opacity > 0.001 else { continue }
            let center = image.center
            let clip = viewProjection.transform(SIMD4(center.x, center.y, center.z, 1))
            guard clip.w > 0 else { continue }
            let ndcX = clip.x / clip.w
            let ndcY = clip.y / clip.w
            guard Swift.abs(ndcX) <= 1.2, Swift.abs(ndcY) <= 1.2 else { continue }

            // Pixel height from a probe half a box up (orthographic-safe).
            let top = viewProjection.transform(
                SIMD4(center.x, center.y + image.size.y / 2, center.z, 1)
            )
            let ndcTopY = top.y / Swift.max(top.w, 1e-6)
            let pixelHeight = Swift.abs(Double(ndcTopY - ndcY)) * height

            let x = (Double(ndcX) * 0.5 + 0.5) * width
            let y = (1 - (Double(ndcY) * 0.5 + 0.5)) * height

            var span = self.span(at: used, dom: dom)
            span.textContent = .string(image.text)
            _ = span.setAttribute("style", """
                position:absolute; left:\(x)px; top:\(y)px; \
                transform:translate(-50%,-50%); font-size:\(pixelHeight)px; \
                line-height:1; opacity:\(Double(image.opacity)); \
                pointer-events:none; user-select:none; white-space:nowrap;
                """)
            used += 1
        }
        if used < visible {
            for index in used..<Swift.min(visible, spans.count) {
                var extra = spans[index]
                _ = extra.setAttribute("style", "display:none")
            }
        }
        visible = used
    }

    private func span(at index: Int, dom: JSObject) -> JSValue {
        while spans.count <= index {
            let span = dom.createElement!("span")
            _ = layer.appendChild(span)
            spans.append(span)
        }
        return spans[index]
    }
}
#endif
