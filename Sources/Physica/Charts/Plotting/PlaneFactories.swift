// Plane plot factories — `plane.graph(of:)` / `plot(points)` / `field { }` /
// `streamlines { }` build the sampled entities (see Graph/VectorField/Streamlines)
// in the plane's space, plus the shared lattice/integration helpers they sample with.

import PhysicaFoundation
import PhysicaTypesetting
import PhysicaKernel

public extension Plane {
    /// Function graph `y = f(x)` sampled uniformly across the x range (the
    /// curve is clipped to the board, so out-of-range stretches stop at the
    /// edge). Reveal it like any shape; re-plot with `graph.plot { ... }`.
    @discardableResult
    func graph(
        of function: (Real) -> Real,
        samples: Int = 160,
        color: Color = .yellow,
        width: Real = 0.025
    ) -> Graph {
        let count = Swift.max(samples, 2)
        let xs = (0..<count).map { index in
            xRange.lowerBound
                + (xRange.upperBound - xRange.lowerBound) * Real(index) / Real(count - 1)
        }
        let points = xs.map { localPoint($0, plotY(function($0))) }
        let graph = Graph(plane: self, sampleXs: xs, lines: [points], color: color, width: width)
        registerPlot(graph)
        return graph
    }

    /// Data series as a polyline (line chart). Points are data coordinates.
    @discardableResult
    func plot(
        _ points: [SIMD2<Real>],
        color: Color = .yellow,
        width: Real = 0.025
    ) -> Graph {
        let line = points.map { localPoint($0.x, plotY($0.y)) }
        let graph = Graph(
            plane: self, sampleXs: points.map(\.x), lines: [line], color: color, width: width
        )
        registerPlot(graph)
        return graph
    }

    /// Vector field arrows on the grid lattice (`step` defaults to `gridStep`).
    /// Arrow length saturates with magnitude; direction is exact.
    @discardableResult
    func field(
        step: Real? = nil,
        color: Color = .teal,
        width: Real = 0.016,
        _ function: (SIMD2<Real>) -> SIMD2<Real>
    ) -> VectorField {
        let lattice = sampleLattice(step: Swift.max(step ?? gridStep, 1e-3), centered: false)
        let vectors = lattice.map { Self.sanitized(function($0)) }
        let field = VectorField(
            plane: self, samplePoints: lattice, vectors: vectors, color: color, width: width
        )
        registerPlot(field)
        return field
    }

    /// Streamlines seeded at cell centers (`seedStep` defaults to `gridStep`),
    /// integrated with fixed-step RK2 in data space.
    @discardableResult
    func streamlines(
        seedStep: Real? = nil,
        steps: Int = 90,
        dt: Real = 0.05,
        color: Color = .blue,
        width: Real = 0.014,
        _ function: (SIMD2<Real>) -> SIMD2<Real>
    ) -> Streamlines {
        let seeds = sampleLattice(step: Swift.max(seedStep ?? gridStep, 1e-3), centered: true)
        let lines = seeds.map { seed in
            integrate(function, from: seed, steps: Swift.max(steps, 1), dt: dt)
                .map { localPoint($0.x, $0.y) }
        }
        let streamlines = Streamlines(
            plane: self, seeds: seeds, steps: Swift.max(steps, 1), dt: dt,
            lines: lines, color: color, width: width
        )
        registerPlot(streamlines)
        return streamlines
    }

    /// Filled region between `function` and `baseline` (area chart). Same
    /// sampling as `graph(of:)`; re-plot with `area.plot { ... }`.
    @discardableResult
    func area(
        of function: (Real) -> Real,
        samples: Int = 160,
        baseline: Real = 0,
        color: Color = .teal,
        opacity: Real = 0.35
    ) -> Area {
        let count = Swift.max(samples, 2)
        let xs = (0..<count).map { index in
            xRange.lowerBound
                + (xRange.upperBound - xRange.lowerBound) * Real(index) / Real(count - 1)
        }
        let points = xs.map { localPoint($0, plotY(function($0))) }
        let area = Area(
            plane: self, sampleXs: xs, lines: [points],
            baseline: baseline, color: color, opacity: opacity
        )
        registerPlot(area)
        return area
    }

    /// Point cloud (scatter chart). Points are data coordinates; re-plot with
    /// `scatter.plot(newPoints)` and the markers glide to their new places.
    @discardableResult
    func scatter(
        _ points: [SIMD2<Real>],
        markerRadius: Real = 0.07,
        color: Color = .yellow
    ) -> Scatter {
        let line = points.map { localPoint($0.x, plotY($0.y)) }
        let scatter = Scatter(
            plane: self, lines: [line], markerRadius: markerRadius, color: color
        )
        registerPlot(scatter)
        return scatter
    }

    /// Parametric curve (x(t), y(t)) sampled uniformly over `t`, clipped to the
    /// board on both axes. Re-plot with `parametric.plot { t in ... }`.
    @discardableResult
    func parametric(
        t range: ClosedRange<Real>,
        samples: Int = 200,
        color: Color = .yellow,
        width: Real = 0.025,
        _ function: (Real) -> SIMD2<Real>
    ) -> Parametric {
        let count = Swift.max(samples, 2)
        let ts = (0..<count).map { index in
            range.lowerBound
                + (range.upperBound - range.lowerBound) * Real(index) / Real(count - 1)
        }
        let points = ts.map { t -> SIMD2<Real> in
            let p = Self.sanitized(function(t))
            return localPoint(p.x, plotY(p.y))
        }
        let parametric = Parametric(
            plane: self, sampleTs: ts, lines: [points], color: color, width: width
        )
        registerPlot(parametric)
        return parametric
    }

    // MARK: Sampling helpers

    /// Lattice of data-space sample points; `centered` offsets by half a step
    /// (streamline seeds start inside cells, not on grid lines).
    private func sampleLattice(step: Real, centered: Bool) -> [SIMD2<Real>] {
        let offset = centered ? step / 2 : 0
        let xs = sampleValues(in: xRange, step: step, offset: offset)
        let ys = sampleValues(in: yRange, step: step, offset: offset)
        var lattice: [SIMD2<Real>] = []
        lattice.reserveCapacity(xs.count * ys.count)
        for y in ys {
            for x in xs {
                lattice.append(SIMD2(x, y))
            }
        }
        return lattice
    }

    /// Fixed-count RK2 walk; the point list always has `steps + 1` entries
    /// (frozen at the exit point once the line leaves the board), keeping
    /// every streamline's topology constant for morphing.
    func integrate(
        _ function: (SIMD2<Real>) -> SIMD2<Real>,
        from seed: SIMD2<Real>, steps: Int, dt: Real
    ) -> [SIMD2<Real>] {
        let maxStep = gridStep / 2
        var points: [SIMD2<Real>] = [seed]
        points.reserveCapacity(steps + 1)
        var p = seed
        var frozen = false
        for _ in 0..<steps {
            if !frozen {
                let k1 = Self.sanitized(function(p))
                let mid = p + k1 * (dt / 2)
                var delta = Self.sanitized(function(mid)) * dt
                let length = delta.distance()
                if length > maxStep { delta *= maxStep / length }
                let next = p + delta
                if xRange.contains(next.x) && yRange.contains(next.y) {
                    p = next
                } else {
                    frozen = true
                }
            }
            points.append(p)
        }
        return points
    }

    static func sanitized(_ vector: SIMD2<Real>) -> SIMD2<Real> {
        vector.x.isFinite && vector.y.isFinite ? vector : .zero
    }
}
