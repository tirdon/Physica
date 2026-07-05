// Annotation primitives — Manim-style entities that point at, frame, or emphasize
// another entity. Each is sugar over PathEntity/Group built in WORLD space around
// the target's `worldBounds` captured **at creation** (identity transform, like a
// `.highlight` border), so the target must be positioned before you build the
// annotation — the same contract as `plane.graph(of:)`. To track a moving target,
// pair with an updater (`note.updater = { ... }`). Edges reuse the scene `Unit`.
//
// All path-based annotations reveal via `.draw` (or `scene.add`); the `Callout`
// label reveals via `.write`. Nothing here imports Foundation/JavaScriptKit —
// everything is host-testable.

// MARK: - Geometry helpers

import PhysicaFoundation
import PhysicaTypesetting

@MainActor
private func edgeNormal(_ edge: Unit) -> SIMD2<Real> {
    let raw = SIMD2<Real>(edge.vector.x, edge.vector.y)
    let length = (raw.x * raw.x + raw.y * raw.y).squareRoot()
    return length > 1e-6 ? raw / length : SIMD2<Real>(0, 1)
}

/// The point on `bounds` in the direction of `normal` (its supporting point for
/// axis-aligned edges; a reasonable corner offset for diagonals).
@MainActor
private func edgePoint(of bounds: Bounds, along normal: SIMD2<Real>) -> SIMD2<Real> {
    let center = SIMD2<Real>(bounds.center.x, bounds.center.y)
    let half = SIMD2<Real>(bounds.size.x, bounds.size.y) / 2
    return center + normal * (Swift.abs(normal.x) * half.x + Swift.abs(normal.y) * half.y)
}

// MARK: - SurroundingRectangle

/// A rounded rectangle framing `target`'s bounds (inflated by `padding`). The
/// persistent, stroke-only sibling of `.highlight` — add it and leave it on screen.
@MainActor
public final class SurroundingRectangle: PathEntity {
    public init(
        of target: Entity, padding: Real = 0.2, cornerRadius: Real = 0.15,
        color: Color = .yellow, width: Real = 0.03
    ) {
        let bounds = target.worldBounds
        let w = bounds.size.x + 2 * padding
        let h = bounds.size.y + 2 * padding
        let radius = Swift.max(0, Swift.min(cornerRadius, Swift.min(w, h) * 0.5))
        super.init(
            path: Path.roundedRect(
                width: w, height: h, cornerRadius: radius,
                center: SIMD2(bounds.center.x, bounds.center.y)
            ),
            style: RenderStyleComponent(
                color: color, strokeColor: color, strokeWidth: width, isFilled: false
            )
        )
        name = "surround"
    }
}

// MARK: - Underline

/// A straight rule beneath `target`'s bounds, spanning its width plus `padding`.
@MainActor
public final class Underline: PathEntity {
    public init(
        of target: Entity, padding: Real = 0.1, gap: Real = 0.12,
        color: Color = .white, width: Real = 0.03
    ) {
        let bounds = target.worldBounds
        let y = bounds.min.y - gap
        super.init(
            path: .line(
                from: SIMD2(bounds.min.x - padding, y),
                to: SIMD2(bounds.max.x + padding, y)
            ),
            style: RenderStyleComponent(
                color: color, strokeColor: color, strokeWidth: width, isFilled: false
            )
        )
        name = "underline"
    }
}

// MARK: - Pointer

/// A filled triangular caret sitting just outside `target`'s `from` edge, tip
/// nearest the target, pointing inward at it.
@MainActor
public final class Pointer: PathEntity {
    public init(
        at target: Entity, from edge: Unit = .top, gap: Real = 0.15,
        size: Real = 0.45, color: Color = .yellow
    ) {
        let bounds = target.worldBounds
        let normal = edgeNormal(edge)
        let perpendicular = SIMD2<Real>(-normal.y, normal.x)
        let tip = edgePoint(of: bounds, along: normal) + normal * gap
        let base = tip + normal * size
        super.init(
            path: .polygon(points: [
                tip,
                base + perpendicular * (size * 0.5),
                base - perpendicular * (size * 0.5),
            ]),
            style: RenderStyleComponent(
                color: color, strokeColor: color, strokeWidth: 0.02, isFilled: true
            )
        )
        name = "pointer"
    }
}

// MARK: - Spotlight

/// Dims the whole frame except a window over `target`: a large filled quad with an
/// inner rounded-rect hole punched out. The fill pass is stencil-XOR (even-odd, the
/// same path that renders glyph holes), so the inner contour subtracts cleanly.
/// `opacity` is the dim strength (the snapshot resolves path alpha from the entity
/// style's opacity, not the color's alpha). Reveal/hide with `fade`.
@MainActor
public final class Spotlight: PathEntity {
    public init(
        on target: Entity, padding: Real = 0.3, cornerRadius: Real = 0.3,
        color: Color = .black, opacity: Real = 0.6, coverage: Real = 200
    ) {
        let bounds = target.worldBounds
        let center = SIMD2(bounds.center.x, bounds.center.y)
        let w = bounds.size.x + 2 * padding
        let h = bounds.size.y + 2 * padding
        let radius = Swift.max(0, Swift.min(cornerRadius, Swift.min(w, h) * 0.5))
        let outer = Path.rect(width: coverage, height: coverage, center: center)
        let hole = Path.roundedRect(width: w, height: h, cornerRadius: radius, center: center)
        super.init(
            path: outer.appending(hole),
            style: RenderStyleComponent(
                color: color, strokeColor: nil, strokeWidth: 0,
                isFilled: true, opacity: opacity
            )
        )
        name = "spotlight"
    }
}

// MARK: - Callout

/// A text label set off `target`'s `edge` with a leader arrow pointing back at it.
/// A `Group` of the leader (drawn under) and the label (on top, shown by default —
/// target `callout.label` to `.write` it instead). Add the whole group, or draw
/// `callout.leader` and write `callout.label` separately.
@MainActor
public final class Callout: Group {
    public let label: TextEntity
    public let leader: PathEntity

    public init(
        _ text: String, pointingAt target: Entity, font: Font,
        edge: Unit = .topRight, distance: Real = 1.2, fontSize: Real = 0.35,
        color: Color = .white, arrow: Bool = true, width: Real = 0.025
    ) {
        let bounds = target.worldBounds
        let normal = edgeNormal(edge)
        let anchor = edgePoint(of: bounds, along: normal)
        let labelCenter = anchor + normal * distance

        let label = TextEntity(text, font: font, fontSize: fontSize, color: color)
        label.position = Position(labelCenter.x, labelCenter.y, 0)
        label.shown()

        // Leader runs from just outside the label (toward the target) to a hair off
        // the target's edge, head at the target.
        let labelBounds = label.localBounds
        let labelHalf = Swift.abs(normal.x) * labelBounds.size.x / 2
            + Swift.abs(normal.y) * labelBounds.size.y / 2
        let leaderStart = labelCenter - normal * (labelHalf + 0.12)
        let leaderEnd = anchor + normal * 0.06
        let start = Position(leaderStart.x, leaderStart.y, 0)
        let end = Position(leaderEnd.x, leaderEnd.y, 0)
        let leader: PathEntity = arrow
            ? Arrow(start: start, end: end, headLength: 0.22, headWidth: 0.16, width: width, color: color)
            : Line(start: start, end: end, width: width, color: color)

        self.label = label
        self.leader = leader
        super.init()
        addChild(leader)
        addChild(label)
        name = "callout"
    }
}
