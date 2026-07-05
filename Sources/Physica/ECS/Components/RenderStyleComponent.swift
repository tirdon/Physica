// Fill/stroke styling consumed by the snapshot pass, plus the procedural
// texture/cap enums it carries. TransformComponent lives alongside in
// TransformComponent.swift.

import PhysicaFoundation
import PhysicaTypesetting

/// Procedural grain the renderer applies to a path's fill and stroke.
/// World-anchored noise — it sticks to the geometry, not the screen.
public enum PathTexture: Sendable, Equatable {
    case flat
    /// Coarse board grain with voids, like chalk on slate.
    case chalk
    /// Fine diagonal graphite striations.
    case pencil
}

/// Stroke end-cap (and joint-sealing) style.
public enum StrokeCap: Sendable, Equatable {
    /// Flat end exactly at the path end; shallow joint gaps may show.
    case butt
    /// Ends extended by half the stroke width — seals joints (the default).
    case square
    /// Discs at ends and joints — best where line ends are visible
    /// (neon highlight, open Lines, trimmed reveals).
    case round
}

/// Fill/stroke styling consumed by the snapshot pass.
public struct RenderStyleComponent: Component {
    public var color: Color
    public var strokeColor: Color?
    /// Normalized 0...1: 1 = 10% of the frame's longest side. At the default
    /// fit-10 camera that is exactly 1 world unit, so values read like world
    /// units there — but strokes scale with the frame if the camera changes.
    public var strokeWidth: Real
    public var cap: StrokeCap
    public var isFilled: Bool
    public var opacity: Real
    public var texture: PathTexture
    /// Neon tube look: the renderer adds a wide translucent glow pass under
    /// the stroke and whitens its core (highlight borders).
    public var neon: Bool

    public init(
        color: Color = .white,
        strokeColor: Color? = nil,
        strokeWidth: Real = 0.04,
        cap: StrokeCap = .square,
        isFilled: Bool = true,
        opacity: Real = 1,
        texture: PathTexture = .flat,
        neon: Bool = false
    ) {
        self.color = color
        self.strokeColor = strokeColor
        self.strokeWidth = strokeWidth
        self.cap = cap
        self.isFilled = isFilled
        self.opacity = opacity
        self.texture = texture
        self.neon = neon
    }

    public var debugString: String {
        "style(\(color.debugDescription), stroke: \(strokeColor?.debugDescription ?? "none"), opacity: \(fmt(opacity, decimals: 2)))"
    }
}

@MainActor
public extension Entity {
    /// `title.textured(.chalk)` / `shape.textured(.pencil)` — chainable; applies
    /// to anything the snapshot turns into path primitives (shapes, text, math).
    @discardableResult
    func textured(_ texture: PathTexture) -> Self {
        var style = components[RenderStyleComponent.self] ?? RenderStyleComponent()
        style.texture = texture
        components[RenderStyleComponent.self] = style
        return self
    }
}
