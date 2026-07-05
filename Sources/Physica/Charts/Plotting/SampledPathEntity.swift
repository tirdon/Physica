// SampledPathEntity — a PathEntity whose geometry is a bag of polylines (`lines`,
// plane-local coordinates). Graphs and streamlines build on it; `PolylineMorphTrack`
// lerps the sample points, which is what makes their data animatable.

import PhysicaFoundation
import PhysicaTypesetting
import PhysicaKernel

@MainActor
open class SampledPathEntity: PathEntity {
    public internal(set) var lines: [[SIMD2<Real>]] = []

    /// Data-space mirror of `lines`, maintained by every `setLines` through
    /// the mapping hooks — the plane re-derives local geometry from it when
    /// its scale changes (`refreshFromData`). Identity off a plane.
    private(set) var dataLines: [[SIMD2<Real>]] = []

    /// Local → data mapping hook; plane-bound subclasses override with the
    /// board's inverse scale.
    func toData(_ point: SIMD2<Real>) -> SIMD2<Real> { point }

    /// Data → local mapping hook; the inverse of `toData`.
    func toLocal(_ point: SIMD2<Real>) -> SIMD2<Real> { point }

    func setLines(_ newLines: [[SIMD2<Real>]]) {
        lines = newLines
        dataLines = newLines.map { $0.map(toData) }
        path = renderPath(from: newLines)
    }

    /// Re-derives the local polylines from the data-space mirror — called by
    /// the plane after a rescale, so plots follow `plane.size(...)` whether it
    /// runs before or after sampling.
    func refreshFromData() {
        setLines(dataLines.map { $0.map(toLocal) })
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
