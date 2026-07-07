// Image — a bitmap entity: `Image("cat.png")` (any URL the page can load —
// relative path, http(s), or a data: URI) drawn in a world-space box. The core
// stays render-agnostic: the snapshot emits an `ImagePrimitive` carrying the
// source (the same primitive emoji glyphs use, with `url` set), the geometry
// consumer skips it, and the web runtime's DOM image layer lays an `<img>`
// over the canvas projected with the frame's view-projection — so move/shift/
// scale/fade animate it through the ordinary entity machinery, and the box
// tracks the camera. Like the emoji layer it rides, the element draws *above*
// the canvas, outside painter's order. Under the dev server's COEP a
// cross-origin source must send CORS headers (the `<img>` is
// crossorigin=anonymous, same as every other CDN fetch here).

import PhysicaFoundation
import PhysicaTypesetting

/// The bitmap payload: `source` + the box it fills, in world units at unit
/// entity scale. The web layer letterboxes (`object-fit: contain`), so a box
/// wider or squarer than the bitmap shows it undistorted at natural aspect.
public struct ImageComponent: Component {
    public var source: String
    public var size: SIMD2<Real>

    public init(source: String, size: SIMD2<Real>) {
        self.source = source
        self.size = size
    }

    public var debugString: String {
        "image('\(source.prefix(32))' \(fmt(size.x, decimals: 2))×\(fmt(size.y, decimals: 2)))"
    }
}

/// `Image("logo.png")` — a 2×2 box at the origin until moved/sized; an empty
/// source renders nothing (safe placeholder, assign `source` later).
/// Reveal with `scene.add` or a `fade` — image boxes have no strokes to write.
@MainActor
public final class Image: Entity {
    public var source: String {
        get { components[ImageComponent.self]?.source ?? "" }
        set {
            var component = components[ImageComponent.self]
                ?? ImageComponent(source: "", size: SIMD2(2, 2))
            component.source = newValue
            components[ImageComponent.self] = component
        }
    }

    /// The box in world units at unit scale (`scale` animations multiply it).
    public var size: SIMD2<Real> {
        get { components[ImageComponent.self]?.size ?? .zero }
        set {
            var component = components[ImageComponent.self]
                ?? ImageComponent(source: "", size: newValue)
            component.size = newValue
            components[ImageComponent.self] = component
        }
    }

    /// `height: nil` keeps a square box; `object-fit: contain` letterboxes the
    /// bitmap to its natural aspect inside whatever box it gets.
    public init(_ source: String, width: Real = 2, height: Real? = nil, opacity: Real = 1) {
        super.init()
        name = source
        components[ImageComponent.self] = ImageComponent(
            source: source, size: SIMD2(width, height ?? width)
        )
        components[RenderStyleComponent.self] = RenderStyleComponent(opacity: opacity)
    }

    public override var localBounds: Bounds {
        let size = self.size
        return Bounds(center: .zero, size: Position(size.x, size.y, 0))
    }
}
