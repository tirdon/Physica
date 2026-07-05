// Path morphing: subdivide both paths to a shared topology (same contour count,
// same point count per contour, aligned starts and winding), then lerp.


public enum PathMorph {
    public struct Matched: Sendable {
        public var from: [FlattenedContour]
        public var to: [FlattenedContour]
    }

    /// Builds topology-matched flattened contours for `a` → `b`.
    public static func matched(_ a: Path, _ b: Path) -> Matched {
        var fa = a.flattened()
        var fb = b.flattened()
        guard !fa.isEmpty || !fb.isEmpty else { return Matched(from: [], to: []) }

        // Pair large shapes together: sort by |area| descending.
        fa.sort { Swift.abs(signedArea($0)) > Swift.abs(signedArea($1)) }
        fb.sort { Swift.abs(signedArea($0)) > Swift.abs(signedArea($1)) }

        // Balance contour counts: extras morph from/to a point at their partner's centroid.
        while fa.count < fb.count {
            let partner = fb[fa.count]
            fa.append(pointContour(at: centroid(partner), like: partner))
        }
        while fb.count < fa.count {
            let partner = fa[fb.count]
            fb.append(pointContour(at: centroid(partner), like: partner))
        }

        var from: [FlattenedContour] = []
        var to: [FlattenedContour] = []
        for (contourA, contourB) in zip(fa, fb) {
            let count = Swift.max(Swift.max(contourA.points.count, contourB.points.count), 32)
            let resampledA = contourA.resampled(count: count)
            var resampledB = contourB.resampled(count: count)

            // Match winding so fills don't invert mid-morph.
            if signedArea(resampledA) * signedArea(resampledB) < 0 {
                resampledB = FlattenedContour(
                    points: resampledB.points.reversed(), isClosed: resampledB.isClosed
                )
            }
            // Align starts of closed contours: rotate B to minimize total distance.
            if resampledA.isClosed && resampledB.isClosed {
                resampledB = rotated(resampledB, toAlignWith: resampledA)
            }
            from.append(resampledA)
            to.append(resampledB)
        }
        return Matched(from: from, to: to)
    }

    /// Lerps matched contours (counts must match — produced by `matched`).
    public static func interpolate(_ matched: Matched, t: Real) -> [FlattenedContour] {
        zip(matched.from, matched.to).map { from, to in
            FlattenedContour(
                points: zip(from.points, to.points).map { SIMD2<Real>.lerp($0, $1, t) },
                isClosed: from.isClosed || to.isClosed
            )
        }
    }

    /// Polygonal Path from flattened contours (morph intermediates).
    public static func path(from contours: [FlattenedContour]) -> Path {
        Path(contours: contours.compactMap { contour in
            guard contour.points.count >= 2 else { return nil }
            return Path.Contour(
                start: contour.points[0],
                segments: contour.points.dropFirst().map { .line(to: $0) },
                isClosed: contour.isClosed
            )
        })
    }

    // MARK: Helpers

    static func signedArea(_ contour: FlattenedContour) -> Real {
        let points = contour.points
        guard points.count >= 3 else { return 0 }
        var area: Real = 0
        for index in 0..<points.count {
            let p = points[index]
            let q = points[(index + 1) % points.count]
            area += p.x * q.y - q.x * p.y
        }
        return area / 2
    }

    static func centroid(_ contour: FlattenedContour) -> SIMD2<Real> {
        guard !contour.points.isEmpty else { return .zero }
        return contour.points.reduce(SIMD2<Real>.zero, +) / Real(contour.points.count)
    }

    private static func pointContour(at point: SIMD2<Real>, like partner: FlattenedContour) -> FlattenedContour {
        FlattenedContour(
            points: Array(repeating: point, count: Swift.max(partner.points.count, 3)),
            isClosed: partner.isClosed
        )
    }

    private static func rotated(
        _ contour: FlattenedContour, toAlignWith reference: FlattenedContour
    ) -> FlattenedContour {
        let count = contour.points.count
        guard count == reference.points.count, count > 0 else { return contour }
        var bestOffset = 0
        var bestCost = Real.infinity
        for offset in 0..<count {
            var cost: Real = 0
            for index in 0..<count {
                let delta = reference.points[index] - contour.points[(index + offset) % count]
                cost += delta.x * delta.x + delta.y * delta.y
                if cost >= bestCost { break }
            }
            if cost < bestCost {
                bestCost = cost
                bestOffset = offset
            }
        }
        guard bestOffset != 0 else { return contour }
        let rotated = Array(contour.points[bestOffset...] + contour.points[..<bestOffset])
        return FlattenedContour(points: rotated, isClosed: contour.isClosed)
    }
}

// The morph/draw/erase animations built on this live in the kernel
// (Animation/MorphAnimations.swift) — this file is pure geometry.
