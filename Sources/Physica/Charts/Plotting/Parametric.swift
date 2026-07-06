// Parametric — a curve (x(t), y(t)) on a `Plane`:
// `plane.parametric(t: 0...(2 * .pi)) { t in SIMD2(.cos(t), .sin(2 * t)) }`.
// The sample ts are fixed at creation so re-plots stay topology-identical and
// lerp pointwise; the rendered path is clipped to the board on both axes.

import PhysicaFoundation
import PhysicaTypesetting
import PhysicaKernel

extension Parametric: GroupAnchored {
    public var anchorGroup: Group { plane }
}

@MainActor
public final class Parametric: SampledPathEntity {
    public let plane: Plane
    /// Parameter samples (fixed at creation for lerp-stable re-plots).
    public let sampleTs: [Real]

    init(plane: Plane, sampleTs: [Real], lines: [[SIMD2<Real>]], color: Color, width: Real) {
        self.plane = plane
        self.sampleTs = sampleTs
        super.init(
            path: Path(),
            style: RenderStyleComponent(
                color: color, strokeColor: color, strokeWidth: width,
                cap: .round, isFilled: false
            )
        )
        name = "parametric"
        setLines(lines)
    }

    override func toData(_ point: SIMD2<Real>) -> SIMD2<Real> {
        SIMD2(plane.dataX(fromLocalX: point.x), plane.dataY(fromLocalY: point.y))
    }

    override func toLocal(_ point: SIMD2<Real>) -> SIMD2<Real> {
        plane.localPoint(point.x, point.y)
    }

    /// Clips to the board on both axes (a parametric curve can exit either);
    /// the y clip reuses `Graph.clipToBand`, the x clip is the same band clip
    /// with coordinates swapped.
    override func renderPath(from lines: [[SIMD2<Real>]]) -> Path {
        let minCorner = plane.localPoint(plane.xRange.lowerBound, plane.yRange.lowerBound)
        let maxCorner = plane.localPoint(plane.xRange.upperBound, plane.yRange.upperBound)
        let clipped = lines
            .flatMap { Graph.clipToBand($0, lower: minCorner.y, upper: maxCorner.y) }
            .map { run in run.map { SIMD2($0.y, $0.x) } }   // swap → clip x as a band
            .flatMap { Graph.clipToBand($0, lower: minCorner.x, upper: maxCorner.x) }
            .map { run in run.map { SIMD2($0.y, $0.x) } }   // swap back
        return Self.polylinePath(clipped)
    }

    /// Morphs the curve to a new parametric function over the same ts.
    @discardableResult
    public func plot(_ function: (Real) -> SIMD2<Real>) -> Animation {
        let points = sampleTs.map { t -> SIMD2<Real> in
            let p = Plane.sanitized(function(t))
            return plane.localPoint(p.x, plane.plotY(p.y))
        }
        return Animation(pairs: [AnimationPair(
            target: self, blueprint: PolylineMorphBlueprint(lines: [points], verb: "plot(parametric)")
        )])
    }
}
