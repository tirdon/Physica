// Mesh morphing. Same-topology meshes (matching UV-grid primitives) lerp directly;
// otherwise both are resampled onto a shared spherical direction grid by raycasting
// from the centroid (good for star-shaped solids; torus↔torus should share grids).

public enum MeshMorph {
    public struct Matched: Sendable {
        public var from: Mesh
        public var to: Mesh
    }

    public static func matched(_ a: Mesh, _ b: Mesh) -> Matched {
        if a.positions.count == b.positions.count, a.indices == b.indices {
            return Matched(from: a, to: b)
        }
        let segments = 28
        let rings = 18
        return Matched(
            from: resampleByDirection(a, segments: segments, rings: rings),
            to: resampleByDirection(b, segments: segments, rings: rings)
        )
    }

    public static func interpolate(_ matched: Matched, t: Real) -> Mesh {
        let positions = zip(matched.from.positions, matched.to.positions).map {
            Position.lerp($0, $1, t)
        }
        let normals = zip(matched.from.normals, matched.to.normals).map {
            Position.lerp($0, $1, t).normalized
        }
        return Mesh(positions: positions, normals: normals, indices: matched.from.indices)
    }

    /// Samples the surface along a spherical grid of directions from the centroid.
    static func resampleByDirection(_ mesh: Mesh, segments: Int, rings: Int) -> Mesh {
        let center = mesh.bounds.center
        var positions: [Position] = []
        positions.reserveCapacity((rings + 1) * (segments + 1))

        for ring in 0...rings {
            let phi = Real.pi * Real(ring) / Real(rings)
            for segment in 0...segments {
                let theta = 2 * Real.pi * Real(segment) / Real(segments)
                let direction = Position(
                    Real.sin(phi) * Real.cos(theta),
                    Real.cos(phi),
                    Real.sin(phi) * Real.sin(theta)
                )
                let distance = farthestHit(mesh: mesh, origin: center, direction: direction) ?? 0.001
                positions.append(center + direction * distance)
            }
        }

        // Normals from the sampled grid itself (central differences).
        let stride = segments + 1
        var normals = [Position](repeating: Position(0, 1, 0), count: positions.count)
        for ring in 0...rings {
            for segment in 0...segments {
                let index = ring * stride + segment
                let nextSegment = ring * stride + ((segment + 1) % stride)
                let previousSegment = ring * stride + ((segment + stride - 1) % stride)
                let nextRing = Swift.min(ring + 1, rings) * stride + segment
                let previousRing = Swift.max(ring - 1, 0) * stride + segment
                let du = positions[nextSegment] - positions[previousSegment]
                let dv = positions[nextRing] - positions[previousRing]
                let normal = dv.cross(du)
                if normal.length > 1e-9 {
                    normals[index] = normal.normalized
                } else {
                    normals[index] = (positions[index] - center).normalized
                }
            }
        }

        return Mesh(
            positions: positions,
            normals: normals,
            indices: Mesh.gridIndices(rows: rings, columns: segments)
        )
    }

    /// Farthest ray-triangle hit (Möller–Trumbore), so the outer surface wins.
    static func farthestHit(mesh: Mesh, origin: Position, direction: Position) -> Real? {
        var best: Real?
        var index = 0
        while index + 2 < mesh.indices.count {
            let a = mesh.positions[Int(mesh.indices[index])]
            let b = mesh.positions[Int(mesh.indices[index + 1])]
            let c = mesh.positions[Int(mesh.indices[index + 2])]
            index += 3

            let edge1 = b - a
            let edge2 = c - a
            let h = direction.cross(edge2)
            let determinant = edge1.dot(h)
            if Swift.abs(determinant) < 1e-9 { continue }
            let inverseDeterminant = 1 / determinant
            let s = origin - a
            let u = s.dot(h) * inverseDeterminant
            if u < -1e-4 || u > 1 + 1e-4 { continue }
            let q = s.cross(edge1)
            let v = direction.dot(q) * inverseDeterminant
            if v < -1e-4 || u + v > 1 + 1e-4 { continue }
            let t = edge2.dot(q) * inverseDeterminant
            if t > 1e-6, t > (best ?? -.infinity) {
                best = t
            }
        }
        return best
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
