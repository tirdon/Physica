// Graph — a plotted curve on a `Plane`: `plane.graph(of: { x in .sin(x) })` for
// functions, `plane.plot(points)` for data series. Re-plotting is an Animation
// (`scene.play(graph.plot { x in .cos(x) })`); `value(at:)`/`point(at:)` read the
// live polyline so annotations track mid-morph.

import PhysicaFoundation
import PhysicaTypesetting
import PhysicaKernel

@MainActor
public final class Graph: SampledPathEntity {
    public let plane: Plane
    /// Data-space sample xs (fixed at creation for function graphs, so
    /// re-plots stay topology-identical and lerp pointwise).
    public let sampleXs: [Real]

    init(plane: Plane, sampleXs: [Real], lines: [[SIMD2<Real>]], color: Color, width: Real) {
        self.plane = plane
        self.sampleXs = sampleXs
        super.init(
            path: Path(),
            style: RenderStyleComponent(
                color: color, strokeColor: color, strokeWidth: width,
                cap: .round, isFilled: false
            )
        )
        name = "graph"
        setLines(lines)
    }

    override func toData(_ point: SIMD2<Real>) -> SIMD2<Real> {
        SIMD2(plane.dataX(fromLocalX: point.x), plane.dataY(fromLocalY: point.y))
    }

    override func toLocal(_ point: SIMD2<Real>) -> SIMD2<Real> {
        plane.localPoint(point.x, point.y)
    }

    /// Clips the rendered curve to the board so an out-of-range stretch stops
    /// at the edge instead of flattening into a "shoulder". The raw `lines`
    /// keep the full samples, so re-plots stay topology-stable and lerp
    /// pointwise.
    override func renderPath(from lines: [[SIMD2<Real>]]) -> Path {
        let lower = plane.localPoint(0, plane.yRange.lowerBound).y
        let upper = plane.localPoint(0, plane.yRange.upperBound).y
        let clipped = lines.flatMap { Self.clipToBand($0, lower: lower, upper: upper) }
        return Self.polylinePath(clipped)
    }

    /// Splits a plane-local polyline into the sub-polylines lying within the
    /// vertical band `lower...upper`, inserting exact crossing points where it
    /// enters or leaves (so the curve meets the board edge precisely instead of
    /// running flat along it). A curve that dips out and back in yields several
    /// runs; one fully inside yields itself.
    static func clipToBand(_ line: [SIMD2<Real>], lower: Real, upper: Real) -> [[SIMD2<Real>]] {
        func inside(_ y: Real) -> Bool { y >= lower && y <= upper }
        guard line.count >= 2 else {
            if let p = line.first, inside(p.y) { return [[p]] }
            return []
        }
        var runs: [[SIMD2<Real>]] = []
        var run: [SIMD2<Real>] = []
        func flush() {
            if run.count >= 2 { runs.append(run) }
            run = []
        }
        for index in 1..<line.count {
            let p = line[index - 1]
            let q = line[index]
            let dy = q.y - p.y
            // Parameter window [t0, t1] of the segment p→q that lies in band.
            var t0: Real = 0
            var t1: Real = 1
            if Swift.abs(dy) < 1e-12 {
                if !inside(p.y) { flush(); continue }  // horizontal & outside
            } else {
                let ta = (lower - p.y) / dy
                let tb = (upper - p.y) / dy
                t0 = Swift.max(0, Swift.min(ta, tb))
                t1 = Swift.min(1, Swift.max(ta, tb))
                if t0 > t1 { flush(); continue }       // segment misses the band
            }
            let a = SIMD2<Real>.lerp(p, q, t0)
            let b = SIMD2<Real>.lerp(p, q, t1)
            if run.isEmpty {
                run.append(a)
            } else if t0 > 0 {
                flush()                                // re-entered after leaving
                run.append(a)
            }
            run.append(b)
            if t1 < 1 { flush() }                      // left before the segment end
        }
        flush()
        return runs
    }
}

// MARK: - Data re-plot animations

public extension Graph {
    /// Morphs the curve to a new function over the same sample xs — data is
    /// animatable like any property: `scene.play(graph.plot { x in .cos(x) })`.
    @discardableResult
    func plot(_ function: (Real) -> Real) -> Animation {
        let points = sampleXs.map { plane.localPoint($0, plane.plotY(function($0))) }
        return Animation(pairs: [AnimationPair(
            target: self, blueprint: PolylineMorphBlueprint(lines: [points], verb: "plot(fn)")
        )])
    }

    /// Morphs to a new data series (sample counts may differ — resampled).
    @discardableResult
    func plot(_ points: [SIMD2<Real>]) -> Animation {
        let line = points.map { plane.localPoint($0.x, plane.plotY($0.y)) }
        return Animation(pairs: [AnimationPair(
            target: self, blueprint: PolylineMorphBlueprint(lines: [line], verb: "plot(data)")
        )])
    }

    // MARK: Annotation data access

    /// Current data value at `x`, read from the live polyline — mid-morph it
    /// returns the interpolated curve, so annotations track the animation.
    func value(at x: Real) -> Real {
        plane.dataY(fromLocalY: localPoint(atDataX: x).y)
    }

    /// World position on the curve at data `x` — drive a marker with an
    /// updater: `dot.updater = { $0.position = graph.point(at: 1.2) }`.
    func point(at x: Real) -> Position {
        let local = localPoint(atDataX: x)
        return worldTransform.applying(to: Position(local.x, local.y, 0))
    }

    /// Finds the bracketing sample pair on the live line (either x direction)
    /// and lerps; outside the sampled range clamps to the nearer end.
    private func localPoint(atDataX x: Real) -> SIMD2<Real> {
        let targetX = plane.localXValue(x)
        guard let line = lines.first, let first = line.first, let last = line.last else {
            return SIMD2(targetX, 0)
        }
        var previous = first
        for point in line.dropFirst() {
            let lower = Swift.min(previous.x, point.x)
            let upper = Swift.max(previous.x, point.x)
            if targetX >= lower - 1e-6 && targetX <= upper + 1e-6 {
                let span = point.x - previous.x
                let raw = Swift.abs(span) > 1e-9 ? (targetX - previous.x) / span : 0
                let t = Swift.min(Swift.max(raw, 0), 1)
                return SIMD2<Real>.lerp(previous, point, t)
            }
            previous = point
        }
        return Swift.abs(targetX - first.x) < Swift.abs(targetX - last.x) ? first : last
    }
}
