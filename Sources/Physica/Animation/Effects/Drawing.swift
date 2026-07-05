// Morph + draw/erase animations — the kernel-side face of the pure matching
// math in PhysicaGeometry (PathMorph / MeshMorph): entity factories, the
// static draw/erase Animation factories, and their scrub-safe tracks.

import PhysicaFoundation
import PhysicaTypesetting

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

// MARK: - Morph animation for MeshEntity

public extension MeshEntity {
    @discardableResult
    func morph(to target: MeshEntity) -> Animation {
        Animation(pairs: [AnimationPair(target: self, blueprint: MeshMorphBlueprint(target: target))])
    }
}

struct MeshMorphBlueprint: AnimationBlueprint {
    let target: MeshEntity
    var debugLabel: String { "morph(to: mesh)" }

    func makeTrack(
        target entity: Entity, duration: TimeInterval, offset: TimeInterval, easing: Easing, in scene: Scene
    ) -> any AnimationTrackProtocol {
        MeshMorphTrack(
            entity: entity, target: target, duration: duration, offset: offset, easing: easing,
            label: "\(name(of: entity)).\(debugLabel)"
        )
    }
}

@MainActor
final class MeshMorphTrack: AnimationTrackProtocol {
    let duration: TimeInterval
    let offset: TimeInterval
    let label: String
    private let easing: Easing
    private let entity: Entity
    private let target: MeshEntity

    private var originalMesh: Mesh?
    private var targetMesh: Mesh?
    private var matched: MeshMorph.Matched?

    init(
        entity: Entity, target: MeshEntity, duration: TimeInterval, offset: TimeInterval,
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
        guard matched == nil, let meshEntity = entity as? MeshEntity else { return }
        originalMesh = meshEntity.mesh
        targetMesh = target.mesh
        matched = MeshMorph.matched(meshEntity.mesh, target.mesh)
    }

    func apply(at clipTime: TimeInterval, in scene: Scene) {
        guard let matched, let meshEntity = entity as? MeshEntity else { return }
        let t = progress(at: clipTime, easing: easing)
        if t <= 0, let originalMesh {
            meshEntity.mesh = originalMesh  // exact source topology at the start
            return
        }
        if t >= 1, let targetMesh {
            meshEntity.mesh = targetMesh
            return
        }
        meshEntity.mesh = MeshMorph.interpolate(matched, t: t)
    }

    func rewind(in scene: Scene) {
        if let originalMesh, let meshEntity = entity as? MeshEntity {
            meshEntity.mesh = originalMesh
        }
    }
}
