// Area — the filled region between a curve and a baseline on a `Plane`:
// `plane.area(of: { x in .sin(x) })`. The raw `lines` are the curve samples
// (identical topology to `Graph`, so `PolylineMorphTrack` animates data
// changes); only `renderPath` differs — each clipped run closes down to the
// baseline and fills.

import PhysicaFoundation
import PhysicaTypesetting
import PhysicaKernel

extension Area: GroupAnchored {
    public var anchorGroup: Group { plane }
}

@MainActor
public final class Area: SampledPathEntity {
    public let plane: Plane
    /// Data-space sample xs (fixed at creation, so re-plots lerp pointwise).
    public let sampleXs: [Real]
    /// Data-space y the region closes down to (clamped into the board).
    public let baseline: Real

    init(
        plane: Plane, sampleXs: [Real], lines: [[SIMD2<Real>]],
        baseline: Real, color: Color, opacity: Real
    ) {
        self.plane = plane
        self.sampleXs = sampleXs
        self.baseline = baseline
        super.init(
            path: Path(),
            style: RenderStyleComponent(color: color, isFilled: true, opacity: opacity)
        )
        name = "area"
        setLines(lines)
    }

    override func toData(_ point: SIMD2<Real>) -> SIMD2<Real> {
        SIMD2(plane.dataX(fromLocalX: point.x), plane.dataY(fromLocalY: point.y))
    }

    override func toLocal(_ point: SIMD2<Real>) -> SIMD2<Real> {
        plane.localPoint(point.x, point.y)
    }

    /// Clips the curve to the board (same band clip as `Graph`), then closes
    /// each surviving run down to the baseline as a filled contour.
    override func renderPath(from lines: [[SIMD2<Real>]]) -> Path {
        let lower = plane.localPoint(0, plane.yRange.lowerBound).y
        let upper = plane.localPoint(0, plane.yRange.upperBound).y
        let baseY = plane.localPoint(0, plane.clampedY(baseline)).y
        let contours = lines
            .flatMap { Graph.clipToBand($0, lower: lower, upper: upper) }
            .compactMap { run -> Path.Contour? in
                guard let first = run.first, let last = run.last, run.count >= 2 else { return nil }
                var segments = run.dropFirst().map { Path.Segment.line(to: $0) }
                segments.append(.line(to: SIMD2(last.x, baseY)))
                segments.append(.line(to: SIMD2(first.x, baseY)))
                return Path.Contour(start: first, segments: segments, isClosed: true)
            }
        return Path(contours: contours)
    }

    /// Morphs the region to a new function over the same sample xs.
    @discardableResult
    public func plot(_ function: (Real) -> Real) -> Animation {
        let points = sampleXs.map { plane.localPoint($0, plane.plotY(function($0))) }
        return Animation(pairs: [AnimationPair(
            target: self, blueprint: PolylineMorphBlueprint(lines: [points], verb: "plot(area)")
        )])
    }
}
