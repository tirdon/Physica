// AlignmentSnap — the pure alignment-snapping math for ⌥-drag.
//
// Platform-neutral (no `#if os(WASI)`, no DOM, no JSKit), so the host build
// type-checks it and `AlignmentSnapTests` exercises it without a GPU or browser.
// `StudioApp` feeds it the dragged element's union bounds at the raw pointer
// position, the bounds of every other element on the slide, and the screen
// centre; it returns the world-space delta to add so the element lands on the
// nearest alignment, plus the guide line(s) to draw.

import Physica

/// A world-space rectangle reduced to the six alignment anchors we snap to: the
/// three X positions (left / centreX / right) and the three Y positions
/// (bottom / centreY / top). Built from an entity's world `Bounds`.
struct SnapBox: Equatable {
    var minX: Real, minY: Real, maxX: Real, maxY: Real
    var centerX: Real { (minX + maxX) / 2 }
    var centerY: Real { (minY + maxY) / 2 }

    init(minX: Real, minY: Real, maxX: Real, maxY: Real) {
        self.minX = minX; self.minY = minY; self.maxX = maxX; self.maxY = maxY
    }

    init(bounds: Bounds) {
        self.init(minX: bounds.min.x, minY: bounds.min.y, maxX: bounds.max.x, maxY: bounds.max.y)
    }

    func shifted(dx: Real, dy: Real) -> SnapBox {
        SnapBox(minX: minX + dx, minY: minY + dy, maxX: maxX + dx, maxY: maxY + dy)
    }

    var xAnchors: [Real] { [minX, centerX, maxX] }
    var yAnchors: [Real] { [minY, centerY, maxY] }
}

/// One alignment guide line to draw, in world coordinates. A `vertical` guide
/// sits at world x = `position` and spans `start…end` in y; a `horizontal` guide
/// is the transpose. `kind` colours it (screen-centre vs element-to-element).
struct SnapGuide: Equatable {
    enum Axis: Equatable { case vertical, horizontal }
    enum Kind: Equatable { case screenCenter, element }
    var axis: Axis
    var position: Real
    var start: Real
    var end: Real
    var kind: Kind
}

/// The result of a snap: the delta to add to the raw drag position, plus the
/// 0…2 guide lines (one per axis that snapped) to draw while it holds.
struct SnapOutcome: Equatable {
    var dx: Real
    var dy: Real
    var guides: [SnapGuide]
    static let none = SnapOutcome(dx: 0, dy: 0, guides: [])
}

enum AlignmentSnap {
    /// Snaps `moving` (the union bounds of the dragged set, already translated to
    /// the raw pointer position) to the nearest alignment within `threshold` world
    /// units. Each axis is resolved independently against the screen centre line
    /// and every box in `others`; the closest of {left, centre, right} (resp.
    /// {bottom, centre, top}) anchor-to-line pairing wins, so the element snaps by
    /// whichever of its edges or centre is nearest an alignment. `frame` sizes the
    /// full-length screen-centre guides; element guides span only the two boxes.
    static func resolve(moving: SnapBox, others: [SnapBox],
                        screenCenter: (x: Real, y: Real),
                        frame: SnapBox, threshold: Real) -> SnapOutcome {
        let hx = bestHit(anchors: moving.xAnchors,
                         lines: candidateLines(screenCenter: screenCenter.x, others: others, \.minX, \.centerX, \.maxX),
                         threshold: threshold)
        let hy = bestHit(anchors: moving.yAnchors,
                         lines: candidateLines(screenCenter: screenCenter.y, others: others, \.minY, \.centerY, \.maxY),
                         threshold: threshold)
        let dx = hx?.delta ?? 0
        let dy = hy?.delta ?? 0
        let moved = moving.shifted(dx: dx, dy: dy)

        var guides: [SnapGuide] = []
        if let hx {
            let lo: Real, hi: Real
            if let s = hx.source { lo = Swift.min(moved.minY, s.minY); hi = Swift.max(moved.maxY, s.maxY) }
            else { lo = frame.minY; hi = frame.maxY }
            guides.append(SnapGuide(axis: .vertical, position: hx.line, start: lo, end: hi, kind: hx.kind))
        }
        if let hy {
            let lo: Real, hi: Real
            if let s = hy.source { lo = Swift.min(moved.minX, s.minX); hi = Swift.max(moved.maxX, s.maxX) }
            else { lo = frame.minX; hi = frame.maxX }
            guides.append(SnapGuide(axis: .horizontal, position: hy.line, start: lo, end: hi, kind: hy.kind))
        }
        return SnapOutcome(dx: dx, dy: dy, guides: guides)
    }

    // MARK: - internals

    /// A candidate alignment line on one axis: its world coordinate, the element
    /// it came from (nil = the screen centre), and how to colour the guide.
    private struct Line { var value: Real; var source: SnapBox?; var kind: SnapGuide.Kind }
    private struct Hit { var delta: Real; var line: Real; var source: SnapBox?; var kind: SnapGuide.Kind }

    /// The screen-centre line first (so it wins ties), then each other box's three
    /// edges/centre. Screen-centre-first ordering makes the search deterministic.
    private static func candidateLines(screenCenter: Real, others: [SnapBox],
                                       _ lo: KeyPath<SnapBox, Real>,
                                       _ mid: KeyPath<SnapBox, Real>,
                                       _ hi: KeyPath<SnapBox, Real>) -> [Line] {
        var lines: [Line] = [Line(value: screenCenter, source: nil, kind: .screenCenter)]
        for o in others {
            lines.append(Line(value: o[keyPath: lo], source: o, kind: .element))
            lines.append(Line(value: o[keyPath: mid], source: o, kind: .element))
            lines.append(Line(value: o[keyPath: hi], source: o, kind: .element))
        }
        return lines
    }

    /// The anchor-to-line pairing with the smallest in-threshold gap; nil if none
    /// is within `threshold`. Strict `<` keeps the first (screen-centre) hit on ties.
    private static func bestHit(anchors: [Real], lines: [Line], threshold: Real) -> Hit? {
        var best: Hit?
        for line in lines {
            for a in anchors {
                let delta = line.value - a
                guard Swift.abs(delta) <= threshold else { continue }
                if best == nil || Swift.abs(delta) < Swift.abs(best!.delta) {
                    best = Hit(delta: delta, line: line.value, source: line.source, kind: line.kind)
                }
            }
        }
        return best
    }
}
