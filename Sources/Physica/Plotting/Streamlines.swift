// Streamlines — field flow lines on a `Plane`: fixed-step midpoint (RK2)
// integration from a seed lattice. Topology is constant (lines freeze where they
// exit the board), so re-plots lerp pointwise: `scene.play(lines.plot { p in ... })`.

import PhysicaMath
import PhysicaGeometry
import PhysicaTypesetting
import PhysicaKernel

@MainActor
public final class Streamlines: SampledPathEntity {
    public let plane: Plane
    public let seeds: [SIMD2<Real>]
    public let steps: Int
    public let dt: Real

    init(
        plane: Plane, seeds: [SIMD2<Real>], steps: Int, dt: Real,
        lines: [[SIMD2<Real>]], color: Color, width: Real
    ) {
        self.plane = plane
        self.seeds = seeds
        self.steps = steps
        self.dt = dt
        super.init(
            path: Path(),
            style: RenderStyleComponent(
                color: color, strokeColor: color, strokeWidth: width,
                cap: .round, isFilled: false, opacity: 0.8
            )
        )
        name = "streamlines"
        setLines(lines)
    }

    override func toData(_ point: SIMD2<Real>) -> SIMD2<Real> {
        SIMD2(plane.dataX(fromLocalX: point.x), plane.dataY(fromLocalY: point.y))
    }

    override func toLocal(_ point: SIMD2<Real>) -> SIMD2<Real> {
        plane.localPoint(point.x, point.y)
    }
}

// MARK: - Data re-plot animation

public extension Streamlines {
    /// Re-integrates from the same seeds (identical topology) and lerps lines.
    @discardableResult
    func plot(_ function: (SIMD2<Real>) -> SIMD2<Real>) -> Animation {
        let lines = seeds.map { seed in
            plane.integrate(function, from: seed, steps: steps, dt: dt)
                .map { plane.localPoint($0.x, $0.y) }
        }
        return Animation(pairs: [AnimationPair(
            target: self, blueprint: PolylineMorphBlueprint(lines: lines, verb: "plot(flow)")
        )])
    }
}
