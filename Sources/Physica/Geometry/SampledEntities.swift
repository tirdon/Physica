// Sampled plot entities — polyline-backed graphs, vector fields, and streamlines
// that live on a `Plane`, plus the `Plane` factories that build them and the data
// re-plot animations. See Plane.swift for the chartboard itself.

// MARK: - Sampled path entities (polyline-backed, data-animatable)

/// PathEntity whose geometry is a bag of polylines (`lines`, plane-local
/// coordinates). Graphs and streamlines build on it; `PolylineMorphTrack`
/// lerps the sample points, which is what makes their data animatable.
@MainActor
open class SampledPathEntity: PathEntity {
    public internal(set) var lines: [[SIMD2<Real>]] = []

    func setLines(_ newLines: [[SIMD2<Real>]]) {
        lines = newLines
        path = renderPath(from: newLines)
    }

    /// Builds the rendered path from the sample lines. Subclasses override to
    /// clip or reshape the geometry while leaving the raw `lines` (the morph
    /// data) untouched; the base mapping is one open contour per polyline.
    func renderPath(from lines: [[SIMD2<Real>]]) -> Path {
        Self.polylinePath(lines)
    }

    static func polylinePath(_ lines: [[SIMD2<Real>]]) -> Path {
        Path(contours: lines.compactMap { points in
            guard let first = points.first, points.count >= 2 else { return nil }
            return Path.Contour(start: first, segments: points.dropFirst().map { .line(to: $0) })
        })
    }
}

/// A plotted curve: `plane.graph(of: { x in .sin(x) })` for functions, or
/// `plane.plot(points)` for data series. Re-plot with an Animation:
/// `scene.play(graph.plot { x in .cos(x) })`.
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
        transform = plane.worldTransform
        setLines(lines)
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

/// Arrow lattice of a vector field. The field values (`vectors`, data space)
/// are the animatable data: `scene.play(field.plot { p in ... })` lerps them
/// and rebuilds the arrows each frame, so heads stay true mid-morph.
@MainActor
public final class VectorField: PathEntity {
    public let plane: Plane
    /// Data-space lattice the field is sampled on (fixed at creation).
    public let samplePoints: [SIMD2<Real>]
    public internal(set) var vectors: [SIMD2<Real>] = []
    /// Longest arrow, world units (a fraction of the lattice cell).
    private let maxLength: Real
    /// Saturation magnitude: |v| = reference draws at half `maxLength`.
    /// Captured at creation and reused by re-plots, so morphs don't renormalize.
    private let reference: Real

    init(
        plane: Plane, samplePoints: [SIMD2<Real>], vectors: [SIMD2<Real>],
        color: Color, width: Real
    ) {
        self.plane = plane
        self.samplePoints = samplePoints
        let cell = plane.gridStep * Swift.min(plane.unitScale.x, plane.unitScale.y)
        self.maxLength = cell * 0.84
        var meanMagnitude: Real = 0
        for vector in vectors {
            meanMagnitude += vector.distance()
        }
        meanMagnitude /= Real(Swift.max(vectors.count, 1))
        self.reference = Swift.max(meanMagnitude, 1e-6)
        super.init(
            path: Path(),
            style: RenderStyleComponent(
                // Filled: the closed head triangles render solid (the open
                // shaft contours have no area, so the fill skips them).
                color: color, strokeColor: color, strokeWidth: width,
                cap: .round, isFilled: true
            )
        )
        name = "field"
        transform = plane.worldTransform
        setVectors(vectors)
    }

    func setVectors(_ newVectors: [SIMD2<Real>]) {
        vectors = newVectors
        rebuildArrows()
    }

    /// Every sample emits shaft + head contours even when degenerate, so the
    /// contour count is constant and trim-reveals/morphs stay aligned.
    private func rebuildArrows() {
        var contours: [Path.Contour] = []
        contours.reserveCapacity(samplePoints.count * 2)
        for (index, point) in samplePoints.enumerated() {
            let p = plane.localPoint(point.x, point.y)
            let v = index < vectors.count ? vectors[index] : .zero
            let scaled = SIMD2(v.x * plane.unitScale.x, v.y * plane.unitScale.y)
            let magnitude = scaled.distance()
            // Smooth saturation: never exceeds maxLength, no per-plot renorm.
            let length = maxLength * magnitude / (magnitude + reference)
            let dir = magnitude > 1e-9 ? scaled / magnitude : SIMD2<Real>(1, 0)
            let normal = SIMD2<Real>(-dir.y, dir.x)
            let a = p - dir * (length / 2)
            let b = p + dir * (length / 2)
            let head = Swift.min(maxLength * 0.38, length * 0.6)
            // Shaft stops at the head's back; the head is a closed triangle
            // so the fill renders it solid.
            contours.append(Path.Contour(
                start: a, segments: [.line(to: b - dir * head)]
            ))
            contours.append(Path.Contour(
                start: b - dir * head + normal * (head * 0.5),
                segments: [.line(to: b), .line(to: b - dir * head - normal * (head * 0.5))],
                isClosed: true
            ))
        }
        path = Path(contours: contours)
    }
}

/// Streamlines of a vector field: fixed-step midpoint (RK2) integration from a
/// seed lattice. Topology is constant (lines freeze where they exit the board),
/// so re-plots lerp pointwise: `scene.play(lines.plot { p in ... })`.
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
        transform = plane.worldTransform
        setLines(lines)
    }
}

// MARK: - Plane factories

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
        return Graph(plane: self, sampleXs: xs, lines: [points], color: color, width: width)
    }

    /// Data series as a polyline (line chart). Points are data coordinates.
    @discardableResult
    func plot(
        _ points: [SIMD2<Real>],
        color: Color = .yellow,
        width: Real = 0.025
    ) -> Graph {
        let line = points.map { localPoint($0.x, plotY($0.y)) }
        return Graph(
            plane: self, sampleXs: points.map(\.x), lines: [line], color: color, width: width
        )
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
        return VectorField(
            plane: self, samplePoints: lattice, vectors: vectors, color: color, width: width
        )
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
        return Streamlines(
            plane: self, seeds: seeds, steps: Swift.max(steps, 1), dt: dt,
            lines: lines, color: color, width: width
        )
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

public extension VectorField {
    /// Lerps the field values to a new function (sampled on the same lattice)
    /// and rebuilds the arrows every frame, so heads point true mid-morph.
    @discardableResult
    func plot(_ function: (SIMD2<Real>) -> SIMD2<Real>) -> Animation {
        let target = samplePoints.map { Plane.sanitized(function($0)) }
        return Animation(pairs: [AnimationPair(
            target: self, blueprint: VectorFieldBlueprint(vectors: target)
        )])
    }
}

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
