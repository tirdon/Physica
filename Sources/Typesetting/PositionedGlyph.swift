// PositionedGlyph — one placed glyph in em units: the shared output of the
// font/markup parsers here and the per-glyph unit of the kernel's
// TextComponent (which typealiases it back in as TextComponent.PositionedGlyph).
// A glyph is either a vector outline (`path`) or an image glyph (`image` —
// emoji and other clusters the outline font can't draw); image glyphs fade in
// during a write instead of stroke-then-fill.

import PhysicaFoundation

/// An image-rendered glyph (an emoji cluster): the backend rasterizes `text`
/// (the web runtime lays it into a DOM emoji layer, which renders native
/// color emoji) into a box of `size` em units sitting on the baseline.
public struct GlyphImage: Sendable, Equatable {
    /// The character cluster rendered as an image.
    public var text: String
    /// Glyph box in em units (width, height above the baseline).
    public var size: SIMD2<Real>

    public init(text: String, size: SIMD2<Real> = SIMD2(1, 1)) {
        self.text = text
        self.size = size
    }
}

public struct PositionedGlyph: Sendable {
    /// Outline in em units (empty for an image glyph).
    public var path: Path
    /// Layout offset in em units (pen position).
    public var offset: SIMD2<Real>
    /// Per-glyph color override; nil inherits the entity's style color.
    public var color: Color?
    /// Per-glyph opacity factor on top of the entity style's opacity.
    public var opacity: Real = 1
    /// Image payload for glyphs the outline font can't draw (emoji); nil for
    /// ordinary vector glyphs.
    public var image: GlyphImage?

    public init(
        path: Path, offset: SIMD2<Real>, color: Color? = nil, opacity: Real = 1,
        image: GlyphImage? = nil
    ) {
        self.path = path
        self.offset = offset
        self.color = color
        self.opacity = opacity
        self.image = image
    }
}
