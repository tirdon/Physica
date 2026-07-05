// PositionedGlyph — one placed glyph outline in em units: the shared output of
// the font/markup parsers here and the per-glyph unit of the kernel's
// TextComponent (which typealiases it back in as TextComponent.PositionedGlyph).

import PhysicaMath
import PhysicaGeometry

public struct PositionedGlyph: Sendable {
    /// Outline in em units.
    public var path: Path
    /// Layout offset in em units (pen position).
    public var offset: SIMD2<Real>
    /// Per-glyph color override; nil inherits the entity's style color.
    public var color: Color?
    /// Per-glyph opacity factor on top of the entity style's opacity.
    public var opacity: Real = 1

    public init(
        path: Path, offset: SIMD2<Real>, color: Color? = nil, opacity: Real = 1
    ) {
        self.path = path
        self.offset = offset
        self.color = color
        self.opacity = opacity
    }
}
