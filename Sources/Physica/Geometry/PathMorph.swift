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

// MARK: - Morph + draw animations for PathEntity

public extension PathEntity {
    /// Morphs this entity's path into `target`'s (topology-matched, then lerped).
    /// Geometry only; captured at clip start.
    @discardableResult
    func morph(to target: PathEntity) -> Animation {
        Animation(pairs: [AnimationPair(target: self, blueprint: PathMorphBlueprint(target: target))])
    }

}

public extension Animation {
    /// Progressive outline reveal, then fill fade — Write for shapes:
    /// `scene.play(.draw(shape))`. Adds the entity to the scene if no earlier
    /// clip did — no `scene.add` needed first.
    static func draw(_ shape: PathEntity) -> Animation {
        Animation(pairs: [AnimationPair(target: shape, blueprint: DrawBlueprint())])
    }

    /// Backward draw: fill fades out, then the outline retracts. The entity
    /// leaves the scene when the clip completes (scrubbing back restores it).
    static func erase(_ shape: PathEntity) -> Animation {
        Animation(pairs: [AnimationPair(target: shape, blueprint: DrawBlueprint(reversed: true))])
    }
}

struct PathMorphBlueprint: AnimationBlueprint {
    let target: PathEntity
    var debugLabel: String { "morph(to: \(String(describing: type(of: target))))" }

    func makeTrack(
        target entity: Entity, duration: TimeInterval, offset: TimeInterval, easing: Easing, in scene: Scene
    ) -> any AnimationTrackProtocol {
        PathMorphTrack(
            entity: entity, target: target, duration: duration, offset: offset, easing: easing,
            label: "\(name(of: entity)).\(debugLabel)"
        )
    }
}

@MainActor
final class PathMorphTrack: AnimationTrackProtocol {
    let duration: TimeInterval
    let offset: TimeInterval
    let label: String
    private let easing: Easing
    private let entity: Entity
    private let target: PathEntity

    private var originalPath: Path?
    private var targetPath: Path?
    private var matched: PathMorph.Matched?

    init(
        entity: Entity, target: PathEntity, duration: TimeInterval, offset: TimeInterval,
        easing: Easing, label: String
    ) {
        self.entity = entity
        self.target = target
        self.duration = max(duration, 0)
        self.offset = max(offset, 0)
        self.easing = easing
        self.label = label
    }

    func begin(in scene: Scene) {
        guard matched == nil, let pathEntity = entity as? PathEntity else { return }
        let from = pathEntity.path
        let to = target.path
        originalPath = from
        targetPath = to
        matched = PathMorph.matched(from, to)
    }

    func apply(at clipTime: TimeInterval, in scene: Scene) {
        guard let matched, let pathEntity = entity as? PathEntity else { return }
        let t = progress(at: clipTime, easing: easing)
        if t <= 0, let originalPath {
            pathEntity.path = originalPath  // exact (Bézier) endpoints at both ends
            return
        }
        if t >= 1, let targetPath {
            pathEntity.path = targetPath
            return
        }
        pathEntity.path = PathMorph.path(from: PathMorph.interpolate(matched, t: t))
    }

    func rewind(in scene: Scene) {
        if let originalPath, let pathEntity = entity as? PathEntity {
            pathEntity.path = originalPath
        }
    }
}

struct DrawBlueprint: AnimationBlueprint {
    /// erase(): same progress mapping run 1 → 0 (fill fades, stroke retracts),
    /// target removed at the end.
    var reversed = false

    var debugLabel: String { reversed ? "erase()" : "draw()" }
    var introducesTarget: Bool { !reversed }
    var removesTargetAtEnd: Bool { reversed }

    func makeTrack(
        target: Entity, duration: TimeInterval, offset: TimeInterval, easing: Easing, in scene: Scene
    ) -> any AnimationTrackProtocol {
        PropertyTrack<Real>(
            target: target, duration: duration, offset: offset, easing: easing,
            label: "\(name(of: target)).\(debugLabel)",
            read: { _ in reversed ? 1 : 0 },  // draw starts hidden, erase starts shown
            write: { entity, value in
                guard var component = entity.components[PathComponent.self] else { return }
                component.strokeProgress = min(value / 0.85, 1)
                component.fillOpacityFactor = Easing.easeOut.apply(max((value - 0.85) / 0.15, 0))
                entity.components[PathComponent.self] = component
            },
            resolveEnd: { _, _ in reversed ? 0 : 1 }
        )
    }
}
