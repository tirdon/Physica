// Mesh — indexed triangles with normals, plus UV-grid primitives. Primitives with
// matching segment counts share topology, which MeshMorph exploits directly.

public struct Mesh: Sendable, Equatable {
    public var positions: [Position]
    public var normals: [Position]
    public var indices: [UInt32]

    public init(positions: [Position], normals: [Position], indices: [UInt32]) {
        self.positions = positions
        self.normals = normals
        self.indices = indices
    }

    public var bounds: Bounds {
        var result = Bounds.empty
        for position in positions {
            result = result.union(position)
        }
        return result
    }

    // MARK: Primitives (UV grids)

    public static func sphere(radius: Real, segments: Int = 24, rings: Int = 16) -> Mesh {
        ellipsoid(radii: SIMD3(radius, radius, radius), segments: segments, rings: rings)
    }

    public static func ellipsoid(radii: SIMD3<Real>, segments: Int = 24, rings: Int = 16) -> Mesh {
        var positions: [Position] = []
        var normals: [Position] = []
        for ring in 0...rings {
            let phi = Real.pi * Real(ring) / Real(rings)  // 0 (top) → π (bottom)
            for segment in 0...segments {
                let theta = 2 * Real.pi * Real(segment) / Real(segments)
                let direction = Position(
                    Real.sin(phi) * Real.cos(theta),
                    Real.cos(phi),
                    Real.sin(phi) * Real.sin(theta)
                )
                positions.append(direction * radii)
                // Ellipsoid normal: ∇((x/a)²+(y/b)²+(z/c)²) ∝ p / radii².
                normals.append((direction / radii).normalized)
            }
        }
        return Mesh(positions: positions, normals: normals, indices: gridIndices(rows: rings, columns: segments))
    }

    public static func torus(
        majorRadius: Real, minorRadius: Real, majorSegments: Int = 32, minorSegments: Int = 16
    ) -> Mesh {
        var positions: [Position] = []
        var normals: [Position] = []
        for major in 0...majorSegments {
            let u = 2 * Real.pi * Real(major) / Real(majorSegments)
            let ringCenter = Position(majorRadius * Real.cos(u), 0, majorRadius * Real.sin(u))
            for minor in 0...minorSegments {
                let v = 2 * Real.pi * Real(minor) / Real(minorSegments)
                let normal = Position(
                    Real.cos(v) * Real.cos(u),
                    Real.sin(v),
                    Real.cos(v) * Real.sin(u)
                )
                positions.append(ringCenter + normal * minorRadius)
                normals.append(normal)
            }
        }
        return Mesh(
            positions: positions, normals: normals,
            indices: gridIndices(rows: majorSegments, columns: minorSegments)
        )
    }

    public static func box(size: SIMD3<Real>) -> Mesh {
        let h = size / 2
        // 6 faces × 4 vertices, hard normals.
        let faces: [(normal: Position, corners: [Position])] = [
            (Position(0, 0, 1), [
                Position(-h.x, -h.y, h.z), Position(h.x, -h.y, h.z),
                Position(h.x, h.y, h.z), Position(-h.x, h.y, h.z),
            ]),
            (Position(0, 0, -1), [
                Position(h.x, -h.y, -h.z), Position(-h.x, -h.y, -h.z),
                Position(-h.x, h.y, -h.z), Position(h.x, h.y, -h.z),
            ]),
            (Position(1, 0, 0), [
                Position(h.x, -h.y, h.z), Position(h.x, -h.y, -h.z),
                Position(h.x, h.y, -h.z), Position(h.x, h.y, h.z),
            ]),
            (Position(-1, 0, 0), [
                Position(-h.x, -h.y, -h.z), Position(-h.x, -h.y, h.z),
                Position(-h.x, h.y, h.z), Position(-h.x, h.y, -h.z),
            ]),
            (Position(0, 1, 0), [
                Position(-h.x, h.y, h.z), Position(h.x, h.y, h.z),
                Position(h.x, h.y, -h.z), Position(-h.x, h.y, -h.z),
            ]),
            (Position(0, -1, 0), [
                Position(-h.x, -h.y, -h.z), Position(h.x, -h.y, -h.z),
                Position(h.x, -h.y, h.z), Position(-h.x, -h.y, h.z),
            ]),
        ]
        var positions: [Position] = []
        var normals: [Position] = []
        var indices: [UInt32] = []
        for face in faces {
            let base = UInt32(positions.count)
            positions.append(contentsOf: face.corners)
            normals.append(contentsOf: [face.normal, face.normal, face.normal, face.normal])
            indices.append(contentsOf: [base, base + 1, base + 2, base, base + 2, base + 3])
        }
        return Mesh(positions: positions, normals: normals, indices: indices)
    }

    public static func plane(width: Real, depth: Real) -> Mesh {
        let hw = width / 2
        let hd = depth / 2
        return Mesh(
            positions: [
                Position(-hw, 0, -hd), Position(hw, 0, -hd),
                Position(hw, 0, hd), Position(-hw, 0, hd),
            ],
            normals: [Position(0, 1, 0), Position(0, 1, 0), Position(0, 1, 0), Position(0, 1, 0)],
            indices: [0, 1, 2, 0, 2, 3]
        )
    }

    static func gridIndices(rows: Int, columns: Int) -> [UInt32] {
        var indices: [UInt32] = []
        indices.reserveCapacity(rows * columns * 6)
        let stride = UInt32(columns + 1)
        for row in 0..<rows {
            for column in 0..<columns {
                let a = UInt32(row) * stride + UInt32(column)
                let b = a + 1
                let c = a + stride
                let d = c + 1
                indices.append(contentsOf: [a, c, b, b, c, d])
            }
        }
        return indices
    }

    public var debugString: String {
        "mesh(v: \(positions.count), tris: \(indices.count / 3))"
    }
}

// MARK: - Component + entity

/// How the renderer lights a mesh.
public enum Shading: Sendable, Equatable {
    case lambert
    /// Cel look: diffuse quantized into `bands` flat steps, plus an
    /// inverted-hull outline (model units; 0 disables it). Note: the hull
    /// inflates along vertex normals, so hard-edged meshes (box) crack
    /// slightly at corners — outlines shine on smooth surfaces.
    case toon(bands: Int, outline: Real)

    /// Default cel: 3 bands + a thin dark outline.
    public static var toon: Shading { .toon(bands: 3, outline: 0.035) }

    public var debugString: String {
        switch self {
        case .lambert: return "lambert"
        case .toon(let bands, let outline):
            return "toon(bands: \(bands), outline: \(fmt(outline, decimals: 3)))"
        }
    }
}

public struct ModelComponent: Component {
    public var mesh: Mesh
    public var color: Color
    public var opacity: Real
    public var shading: Shading

    public init(mesh: Mesh, color: Color = .blue, opacity: Real = 1, shading: Shading = .lambert) {
        self.mesh = mesh
        self.color = color
        self.opacity = opacity
        self.shading = shading
    }

    public var debugString: String { mesh.debugString }
}

@MainActor
open class MeshEntity: Entity {
    public var mesh: Mesh {
        get { components[ModelComponent.self]?.mesh ?? Mesh(positions: [], normals: [], indices: []) }
        set {
            var component = components[ModelComponent.self] ?? ModelComponent(mesh: newValue)
            component.mesh = newValue
            components[ModelComponent.self] = component
        }
    }

    public init(mesh: Mesh, color: Color = .blue) {
        super.init()
        components[ModelComponent.self] = ModelComponent(mesh: mesh, color: color)
    }

    /// `ball.shaded(.toon)` — chainable, like PathEntity's `stroke(_:width:)`.
    @discardableResult
    public func shaded(_ shading: Shading) -> Self {
        components[ModelComponent.self]?.shading = shading
        return self
    }

    public override init() {
        super.init()
    }

    open override var localBounds: Bounds {
        components[ModelComponent.self]?.mesh.bounds ?? .empty
    }
}
