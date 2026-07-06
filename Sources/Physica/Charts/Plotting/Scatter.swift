// Scatter — a point cloud on a `Plane`: `plane.scatter(points)`. The single
// polyline in `lines` holds the marker centers, so `PolylineMorphTrack`
// animates data changes as markers gliding to their new positions;
// `renderPath` stamps one filled disc per (on-board) center.

import PhysicaFoundation
import PhysicaTypesetting
import PhysicaKernel

extension Scatter: GroupAnchored {
    public var anchorGroup: Group { plane }
}

@MainActor
public final class Scatter: SampledPathEntity {
    public let plane: Plane
    /// Marker radius in plane-local (world) units.
    public let markerRadius: Real

    init(plane: Plane, lines: [[SIMD2<Real>]], markerRadius: Real, color: Color) {
        self.plane = plane
        self.markerRadius = markerRadius
        super.init(
            path: Path(),
            style: RenderStyleComponent(color: color, isFilled: true)
        )
        name = "scatter"
        setLines(lines)
    }

    override func toData(_ point: SIMD2<Real>) -> SIMD2<Real> {
        SIMD2(plane.dataX(fromLocalX: point.x), plane.dataY(fromLocalY: point.y))
    }

    override func toLocal(_ point: SIMD2<Real>) -> SIMD2<Real> {
        plane.localPoint(point.x, point.y)
    }

    /// One disc per marker center inside the board; off-board points simply
    /// don't render (the raw samples stay, so morphs can carry them back in).
    override func renderPath(from lines: [[SIMD2<Real>]]) -> Path {
        let min = plane.localPoint(plane.xRange.lowerBound, plane.yRange.lowerBound)
        let max = plane.localPoint(plane.xRange.upperBound, plane.yRange.upperBound)
        var contours: [Path.Contour] = []
        for line in lines {
            for center in line
            where center.x >= min.x - 1e-6 && center.x <= max.x + 1e-6
                && center.y >= min.y - 1e-6 && center.y <= max.y + 1e-6 {
                contours.append(contentsOf: Path.circle(radius: markerRadius, center: center).contours)
            }
        }
        return Path(contours: contours)
    }

    /// Morphs the markers to a new data series (counts may differ — resampled
    /// index-paired, like every polyline morph).
    @discardableResult
    public func plot(_ points: [SIMD2<Real>]) -> Animation {
        let line = points.map { plane.localPoint($0.x, plane.plotY($0.y)) }
        return Animation(pairs: [AnimationPair(
            target: self, blueprint: PolylineMorphBlueprint(lines: [line], verb: "plot(scatter)")
        )])
    }
}
