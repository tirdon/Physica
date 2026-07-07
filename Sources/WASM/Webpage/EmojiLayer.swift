// EmojiLayer — the DOM overlay that draws every `ImagePrimitive`: emoji
// glyphs as absolutely-positioned spans (native color emoji — no glyph atlas,
// no texture pipeline) and `Image` entity bitmaps as `<img>` elements
// (object-fit contain, crossorigin for COEP), both projected with the same
// view-projection the renderer draws with (the DebugOverlay recipe). Write
// fades ride the primitive's resolved opacity. Elements are pooled per kind
// and re-styled each frame; extras hide.

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
    private var visibleSpans = 0
    private var imgs: [JSValue] = []
    private var visibleImgs = 0

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

        var usedSpans = 0
        var usedImgs = 0
        for primitive in snapshot.primitives {
            guard case .image(let image) = primitive, image.opacity > 0.001 else { continue }
            let center = image.center
            let clip = viewProjection.transform(SIMD4(center.x, center.y, center.z, 1))
            guard clip.w > 0 else { continue }
            let ndcX = clip.x / clip.w
            let ndcY = clip.y / clip.w
            guard Swift.abs(ndcX) <= 1.2, Swift.abs(ndcY) <= 1.2 else { continue }

            // Pixel height from a probe half a box up (orthographic-safe; the
            // half-box probe and the 0.5 px-per-NDC factor cancel, so this is
            // the full box height).
            let top = viewProjection.transform(
                SIMD4(center.x, center.y + image.size.y / 2, center.z, 1)
            )
            let ndcTopY = top.y / Swift.max(top.w, 1e-6)
            let pixelHeight = Swift.abs(Double(ndcTopY - ndcY)) * height

            let x = (Double(ndcX) * 0.5 + 0.5) * width
            let y = (1 - (Double(ndcY) * 0.5 + 0.5)) * height

            // A bitmap (`Image` entity): an <img> letterboxed into the box.
            if let url = image.url {
                let right = viewProjection.transform(
                    SIMD4(center.x + image.size.x / 2, center.y, center.z, 1)
                )
                let ndcRightX = right.x / Swift.max(right.w, 1e-6)
                let pixelWidth = Swift.abs(Double(ndcRightX - ndcX)) * width

                var img = self.img(at: usedImgs, dom: dom)
                if img.getAttribute("src").string != url {
                    _ = img.setAttribute("src", url)
                }
                _ = img.setAttribute("style", """
                    position:absolute; left:\(x)px; top:\(y)px; \
                    transform:translate(-50%,-50%); \
                    width:\(pixelWidth)px; height:\(pixelHeight)px; \
                    object-fit:contain; opacity:\(Double(image.opacity)); \
                    pointer-events:none; user-select:none;
                    """)
                usedImgs += 1
                continue
            }

            var span = self.span(at: usedSpans, dom: dom)
            span.textContent = .string(image.text)
            _ = span.setAttribute("style", """
                position:absolute; left:\(x)px; top:\(y)px; \
                transform:translate(-50%,-50%); font-size:\(pixelHeight)px; \
                line-height:1; opacity:\(Double(image.opacity)); \
                pointer-events:none; user-select:none; white-space:nowrap;
                """)
            usedSpans += 1
        }
        hideExtras(spans, from: usedSpans, upTo: visibleSpans)
        hideExtras(imgs, from: usedImgs, upTo: visibleImgs)
        visibleSpans = usedSpans
        visibleImgs = usedImgs
    }

    private func hideExtras(_ pool: [JSValue], from used: Int, upTo visible: Int) {
        guard used < visible else { return }
        for index in used..<Swift.min(visible, pool.count) {
            var extra = pool[index]
            _ = extra.setAttribute("style", "display:none")
        }
    }

    private func span(at index: Int, dom: JSObject) -> JSValue {
        while spans.count <= index {
            let span = dom.createElement!("span")
            _ = layer.appendChild(span)
            spans.append(span)
        }
        return spans[index]
    }

    private func img(at index: Int, dom: JSObject) -> JSValue {
        while imgs.count <= index {
            var img = dom.createElement!("img")
            // COEP: cross-origin sources must answer with CORS headers, same
            // as every CDN fetch on the page; data:/same-origin unaffected.
            img.crossOrigin = .string("anonymous")
            _ = img.setAttribute("draggable", "false")
            _ = layer.appendChild(img)
            imgs.append(img)
        }
        return imgs[index]
    }
}
#endif
