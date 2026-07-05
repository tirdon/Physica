// VectorField — the arrow lattice of a vector field on a `Plane`. The field
// values (`vectors`, data space) are the animatable data:
// `scene.play(field.plot { p in ... })` lerps them and rebuilds the arrows each
// frame, so heads stay true mid-morph.

import PhysicaMath
import PhysicaGeometry
import PhysicaTypesetting
import PhysicaKernel

@MainActor
public final class VectorField: PathEntity {
    public let plane: Plane
    /// Data-space lattice the field is sampled on (fixed at creation).
    public let samplePoints: [SIMD2<Real>]
    public internal(set) var vectors: [SIMD2<Real>] = []
    /// Longest arrow, world units (a fraction of the lattice cell) — derived
    /// from the live board scale, so a plane rescale resizes the arrows.
    private var maxLength: Real {
        plane.gridStep * Swift.min(plane.unitScale.x, plane.unitScale.y) * 0.84
    }
    /// Saturation magnitude: |v| = reference draws at half `maxLength`.
    /// Captured at creation and reused by re-plots, so morphs don't renormalize.
    private let reference: Real

    init(
        plane: Plane, samplePoints: [SIMD2<Real>], vectors: [SIMD2<Real>],
        color: Color, width: Real
    ) {
        self.plane = plane
        self.samplePoints = samplePoints
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
        setVectors(vectors)
    }

    func setVectors(_ newVectors: [SIMD2<Real>]) {
        vectors = newVectors
        rebuildArrows()
    }

    /// Re-maps the data-space vectors through the new board scale — called by
    /// the plane after a rescale.
    func refresh() {
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

// MARK: - Data re-plot animation

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
