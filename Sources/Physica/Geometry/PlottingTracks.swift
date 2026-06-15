// Plotting tracks — animatable backings for re-plotting: PolylineMorphTrack
// (graphs/streamlines, index-paired arc-length resample) and VectorFieldTrack
// (fields, arrows rebuilt per frame). See SampledEntities.swift for the entities.

// MARK: - Tracks

struct PolylineMorphBlueprint: AnimationBlueprint {
    let lines: [[SIMD2<Real>]]
    let verb: String
    var debugLabel: String { verb }

    func makeTrack(
        target: Entity, duration: TimeInterval, offset: TimeInterval, easing: Easing, in scene: Scene
    ) -> any AnimationTrackProtocol {
        PolylineMorphTrack(
            entity: target, to: lines, duration: duration, offset: offset, easing: easing,
            label: "\(name(of: target)).\(debugLabel)"
        )
    }
}

/// Lerps polyline sample points index-to-index (no contour sorting — line N
/// stays line N, unlike `PathMorph`, which would scramble many-line bundles).
@MainActor
final class PolylineMorphTrack: AnimationTrackProtocol {
    let duration: TimeInterval
    let offset: TimeInterval
    let label: String
    private let easing: Easing
    private let entity: Entity
    private let to: [[SIMD2<Real>]]

    private var from: [[SIMD2<Real>]]?
    private var matchedFrom: [[SIMD2<Real>]]?
    private var matchedTo: [[SIMD2<Real>]]?

    init(
        entity: Entity, to: [[SIMD2<Real>]], duration: TimeInterval, offset: TimeInterval,
        easing: Easing, label: String
    ) {
        self.entity = entity
        self.to = to
        self.duration = max(duration, 0)
        self.offset = max(offset, 0)
        self.easing = easing
        self.label = label
    }

    func begin(in scene: Scene) {
        guard from == nil, let sampled = entity as? SampledPathEntity else { return }
        let start = sampled.lines
        from = start
        let matched = Self.matched(start, to)
        matchedFrom = matched.from
        matchedTo = matched.to
    }

    func apply(at clipTime: TimeInterval, in scene: Scene) {
        guard let sampled = entity as? SampledPathEntity,
              let from, let matchedFrom, let matchedTo else { return }
        let t = progress(at: clipTime, easing: easing)
        if t <= 0 {
            sampled.setLines(from)  // exact sample data at both endpoints
            return
        }
        if t >= 1 {
            sampled.setLines(to)
            return
        }
        sampled.setLines(zip(matchedFrom, matchedTo).map { a, b in
            zip(a, b).map { SIMD2<Real>.lerp($0, $1, t) }
        })
    }

    func rewind(in scene: Scene) {
        if let from, let sampled = entity as? SampledPathEntity {
            sampled.setLines(from)
        }
    }

    /// Index-paired topology match: per-line arc-length resample to the larger
    /// count; a missing partner collapses to/grows from the existing line's
    /// first point.
    static func matched(
        _ a: [[SIMD2<Real>]], _ b: [[SIMD2<Real>]]
    ) -> (from: [[SIMD2<Real>]], to: [[SIMD2<Real>]]) {
        var from: [[SIMD2<Real>]] = []
        var to: [[SIMD2<Real>]] = []
        let count = Swift.max(a.count, b.count)
        for index in 0..<count {
            var lineA = index < a.count ? a[index] : []
            var lineB = index < b.count ? b[index] : []
            let anchorA = lineA.first ?? lineB.first ?? .zero
            let anchorB = lineB.first ?? lineA.first ?? .zero
            if lineA.count < 2 { lineA = [lineA.first ?? anchorB, lineA.first ?? anchorB] }
            if lineB.count < 2 { lineB = [lineB.first ?? anchorA, lineB.first ?? anchorA] }
            let resolved = Swift.max(lineA.count, lineB.count)
            from.append(
                FlattenedContour(points: lineA, isClosed: false).resampled(count: resolved).points
            )
            to.append(
                FlattenedContour(points: lineB, isClosed: false).resampled(count: resolved).points
            )
        }
        return (from, to)
    }
}

struct VectorFieldBlueprint: AnimationBlueprint {
    let vectors: [SIMD2<Real>]
    var debugLabel: String { "plot(field)" }

    func makeTrack(
        target: Entity, duration: TimeInterval, offset: TimeInterval, easing: Easing, in scene: Scene
    ) -> any AnimationTrackProtocol {
        VectorFieldTrack(
            entity: target, to: vectors, duration: duration, offset: offset, easing: easing,
            label: "\(name(of: target)).\(debugLabel)"
        )
    }
}

/// Lerps the field's sample vectors; the entity rebuilds its arrows from them.
@MainActor
final class VectorFieldTrack: AnimationTrackProtocol {
    let duration: TimeInterval
    let offset: TimeInterval
    let label: String
    private let easing: Easing
    private let entity: Entity
    private let to: [SIMD2<Real>]
    private var from: [SIMD2<Real>]?

    init(
        entity: Entity, to: [SIMD2<Real>], duration: TimeInterval, offset: TimeInterval,
        easing: Easing, label: String
    ) {
        self.entity = entity
        self.to = to
        self.duration = max(duration, 0)
        self.offset = max(offset, 0)
        self.easing = easing
        self.label = label
    }

    func begin(in scene: Scene) {
        guard from == nil, let field = entity as? VectorField else { return }
        from = field.vectors
    }

    func apply(at clipTime: TimeInterval, in scene: Scene) {
        guard let field = entity as? VectorField, let from else { return }
        let t = progress(at: clipTime, easing: easing)
        if t <= 0 { field.setVectors(from); return }
        if t >= 1 { field.setVectors(to); return }
        let count = Swift.min(from.count, to.count)
        field.setVectors((0..<count).map { SIMD2<Real>.lerp(from[$0], to[$0], t) })
    }

    func rewind(in scene: Scene) {
        if let from, let field = entity as? VectorField {
            field.setVectors(from)
        }
    }
}
