// Sprite — the in-canvas bitmap: `Image`'s WebGPU sibling. Same world-space
// box semantics (any URL / data: URI, square unless `height:` given, moved/
// scaled/rotated/faded by the ordinary machinery), but the renderer draws it
// as a textured quad in 2D painter's order — scene content added after it
// paints over it, unlike `Image`, whose DOM `<img>` always sits above the
// canvas. The texture uploads once per URL via copyExternalImageToTexture;
// frames before the decode resolves simply skip the quad. The bitmap
// letterboxes into the box (contain-fit in the shader), so aspect is never
// distorted. Reveal via `scene.add`/`fade` — there are no strokes to write.
// An empty source renders nothing (safe placeholder).

import PhysicaFoundation
import PhysicaAlgebra
import PhysicaTypesetting

/// The bitmap box an entity shows in-canvas: a source URL and a world-space
/// box size. Opacity rides the shared `RenderStyleComponent`.
public struct SpriteComponent: Component {
    public var source: String
    public var size: SIMD2<Real>

    public init(source: String, size: SIMD2<Real>) {
        self.source = source
        self.size = size
    }

    public var debugString: String {
        "sprite('\(source.prefix(32))' \(fmt(size.x, decimals: 2))×\(fmt(size.y, decimals: 2)))"
    }
}

@MainActor
public final class Sprite: Entity {
    public var source: String {
        get { components[SpriteComponent.self]?.source ?? "" }
        set { components[SpriteComponent.self]?.source = newValue }
    }

    public var size: SIMD2<Real> {
        get { components[SpriteComponent.self]?.size ?? .zero }
        set { components[SpriteComponent.self]?.size = newValue }
    }

    public init(_ source: String, width: Real = 2, height: Real? = nil, opacity: Real = 1) {
        super.init()
        name = source
        components[SpriteComponent.self] = SpriteComponent(
            source: source, size: SIMD2(width, height ?? width)
        )
        components[RenderStyleComponent.self] = RenderStyleComponent(opacity: opacity)
    }

    /// The box bounds — enables `move(to: Unit)`, `.highlight`, and hit-testing.
    public override var localBounds: Bounds {
        let size = self.size
        return Bounds(center: .zero, size: Position(size.x, size.y, 0))
    }
}
