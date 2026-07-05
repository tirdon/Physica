// LiteralEntity + GlyphSlice.makeLiteral — turning a slice of a monolithic
// formula into a draggable expression atom.
//
// A MathJax formula is one TextEntity whose glyphs carry no semantics (MathSVG
// strips them). `makeLiteral` is the escape hatch: the author names what a slice
// MEANS, and it becomes a draggable carrying that payload. The clone overlays
// the source — it FOLLOWS the source glyphs' world center every frame (so it
// rides an animating formula) until the drag coordinator grabs it, which fires
// `onDragBegan` and detaches the follow updater.

import PhysicaFoundation
import PhysicaAlgebra
import PhysicaTypesetting
import PhysicaKernel

public enum LiteralKind: Sendable, Equatable {
    case identifier(String)
    case numerical(String)
    case symbolic(String)
    case expressionTex(String)
    case projection(ProjectionAxis)

    /// TeX the kind parses from (nil for a projection operator).
    public var tex: String? {
        switch self {
        case .identifier(let t), .numerical(let t), .symbolic(let t), .expressionTex(let t): return t
        case .projection: return nil
        }
    }

    /// What this literal carries to a drop target.
    public var payload: DragPayload {
        switch self {
        case .projection(let axis):
            return .projection(axis)
        default:
            if let tex, let expression = try? Expression(parsing: tex) {
                return .expression(expression)
            }
            return .tag(tex ?? "literal")
        }
    }
}

@MainActor
public final class LiteralEntity: Entity {
    public let kind: LiteralKind
    private var followID: UInt64?

    /// True until the literal is grabbed (then it stops tracking its source).
    public var isFollowingSource: Bool { followID != nil }

    public var textComponent: TextComponent {
        get { components[TextComponent.self] ?? TextComponent() }
        set { components[TextComponent.self] = newValue }
    }

    init(
        kind: LiteralKind,
        glyphs: [TextComponent.PositionedGlyph],
        fontSize: Real,
        color: Color,
        follow: @escaping @MainActor () -> Position?
    ) {
        self.kind = kind
        super.init()
        name = "literal"
        components[TextComponent.self] = TextComponent(glyphs: glyphs, fontSize: fontSize, writeProgress: 1)
        components[RenderStyleComponent.self] = RenderStyleComponent(
            color: color, strokeColor: color, strokeWidth: 0.012 * fontSize, isFilled: true
        )
        components[DraggableComponent.self] = DraggableComponent(
            payload: kind.payload,
            onDragBegan: { [weak self] _ in self?.detachFollow() }
        )
        followID = addUpdater { entity in
            if let point = follow() { entity.position = point }
        }
    }

    public override var localBounds: Bounds {
        LiteralEntity.glyphBounds(textComponent.glyphs, fontSize: textComponent.fontSize)
    }

    /// Stops tracking the source — called the moment the literal is grabbed.
    func detachFollow() {
        if let id = followID {
            removeUpdater(id: id)
            followID = nil
        }
    }

    package static func glyphBounds(_ glyphs: [TextComponent.PositionedGlyph], fontSize: Real) -> Bounds {
        var bounds = Bounds.empty
        for glyph in glyphs {
            let path = glyph.path.translated(by: glyph.offset).scaled(by: fontSize)
            bounds = bounds.union(path.bounds)
        }
        return bounds
    }
}

public extension GlyphSlice {
    /// Clones this slice's glyphs into a draggable `LiteralEntity` whose meaning
    /// the author supplies. Out-of-range slices clamp against the live glyph
    /// count, so they make a smaller (or empty) literal rather than trapping.
    @discardableResult
    func makeLiteral(_ kind: LiteralKind) -> LiteralEntity {
        let component = text.textComponent
        let clamped = range.clamped(to: 0..<component.glyphs.count)
        var glyphs = clamped.map { component.glyphs[$0] }
        let fontSize = component.fontSize

        // Re-center the cloned glyphs so the literal's local origin is the slice
        // center; its `position` then places it (assuming identity source scale).
        let center = LiteralEntity.glyphBounds(glyphs, fontSize: fontSize).center
        let shift = fontSize == 0 ? .zero : SIMD2<Real>(center.x / fontSize, center.y / fontSize)
        for index in glyphs.indices { glyphs[index].offset -= shift }

        let color = text.components[RenderStyleComponent.self]?.color ?? .white
        let sourceText = text
        let indices = clamped
        let follow: @MainActor () -> Position? = { [weak sourceText] in
            guard let sourceText, let component = sourceText.components[TextComponent.self] else { return nil }
            var bounds = Bounds.empty
            for index in indices where index < component.glyphs.count {
                let glyph = component.glyphs[index]
                let path = glyph.path.translated(by: glyph.offset).scaled(by: component.fontSize)
                bounds = bounds.union(path.bounds)
            }
            guard !bounds.isEmpty else { return nil }
            return sourceText.worldTransform.applying(to: bounds.center)
        }

        let literal = LiteralEntity(kind: kind, glyphs: glyphs, fontSize: fontSize, color: color, follow: follow)
        if let initial = follow() { literal.position = initial }  // overlay before the first frame
        return literal
    }
}
