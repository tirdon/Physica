// GeometryUploader — turns a SceneSnapshot into flat GPU-ready arrays + a draw list.
// Per-frame rebuild: one flat-vertex stream, one mesh stream, one uniform block.

#if os(WASI)
import Physica

struct DrawCommand {
    enum Kind {
        case pathStencil
        case pathCover
        case stroke
        case mesh
    }

    var kind: Kind
    /// Vertex range in the flat stream (pathStencil/pathCover/stroke).
    var vertexStart: Int = 0
    var vertexCount: Int = 0
    /// Index range + base vertex in the mesh stream (mesh).
    var indexStart: Int = 0
    var indexCount: Int = 0
    var baseVertex: Int = 0
    /// Byte offset into the per-draw uniform buffer.
    var uniformOffset: Int
}

struct FramePacket {
    var flatVertices: [Float32] = []     // x, y, z
    var meshVertices: [Float32] = []     // x, y, z, nx, ny, nz
    var meshIndices: [UInt32] = []
    var uniforms: [Float32] = []         // 64 floats (256 bytes) per draw slot
    var commands: [DrawCommand] = []

    static let uniformSlotFloats = 64
    static let uniformSlotBytes = 256
}

enum GeometryUploader {
    static func pack(_ snapshot: SceneSnapshot) -> FramePacket {
        var packet = FramePacket()

        // Meshes first: they depth-test; 2D paths paint over in snapshot order.
        for primitive in snapshot.primitives {
            if case .mesh(let mesh) = primitive {
                appendMesh(mesh, into: &packet)
            }
        }
        for primitive in snapshot.primitives {
            if case .path(let path) = primitive {
                appendPath(path, into: &packet)
            }
        }
        return packet
    }

    // MARK: Uniform slots

    private static func appendUniformSlot(model: Matrix4, color: Color, into packet: inout FramePacket) -> Int {
        let offset = packet.uniforms.count * 4
        packet.uniforms.append(contentsOf: model.floatArray)
        packet.uniforms.append(contentsOf: [color.r, color.g, color.b, color.a])
        packet.uniforms.append(contentsOf: [0, 0, 0, 0])
        let pad = FramePacket.uniformSlotFloats - 24
        packet.uniforms.append(contentsOf: [Float32](repeating: 0, count: pad))
        return offset
    }

    // MARK: Meshes

    private static func appendMesh(_ mesh: MeshDraw, into packet: inout FramePacket) {
        let slot = appendUniformSlot(
            model: mesh.model,
            color: mesh.color.with(opacity: Float(mesh.opacity)),
            into: &packet
        )
        let baseVertex = packet.meshVertices.count / 6
        for index in 0..<mesh.positions.count {
            let p = mesh.positions[index]
            let n = index < mesh.normals.count ? mesh.normals[index] : Position(0, 0, 1)
            packet.meshVertices.append(contentsOf: [
                Float32(p.x), Float32(p.y), Float32(p.z),
                Float32(n.x), Float32(n.y), Float32(n.z),
            ])
        }
        let indexStart = packet.meshIndices.count
        packet.meshIndices.append(contentsOf: mesh.indices)
        packet.commands.append(DrawCommand(
            kind: .mesh,
            indexStart: indexStart,
            indexCount: mesh.indices.count,
            baseVertex: baseVertex,
            uniformOffset: slot
        ))
    }

    // MARK: Paths

    private static func appendPath(_ path: PathPrimitive, into packet: inout FramePacket) {
        if let fill = path.style.fill {
            let color = fill.with(opacity: Float(path.fillOpacityFactor))
            if color.a > 0.001 {
                appendFill(path, color: color, into: &packet)
            }
        }
        if let stroke = path.style.stroke, path.strokeProgress > 0.0001 {
            appendStroke(path, color: stroke, into: &packet)
        }
    }

    private static func appendFill(_ path: PathPrimitive, color: Color, into packet: inout FramePacket) {
        let slot = appendUniformSlot(model: .identity, color: color, into: &packet)

        // Pass A: triangle fans (apex = first point) into the stencil, all contours.
        let fanStart = packet.flatVertices.count / 3
        var minPoint = Position(.infinity, .infinity, .infinity)
        var maxPoint = Position(-.infinity, -.infinity, -.infinity)

        for contour in path.contours where contour.points.count >= 3 {
            let apex = contour.points[0]
            for index in 1..<(contour.points.count - 1) {
                appendFlat(apex, into: &packet)
                appendFlat(contour.points[index], into: &packet)
                appendFlat(contour.points[index + 1], into: &packet)
            }
            // Closed contours include the implicit closing wedge.
            if contour.isClosed, contour.points.count >= 3 {
                // fan (apex, last, first) is degenerate; winding already closed by fan shape
            }
            for point in contour.points {
                minPoint = Position(
                    Swift.min(minPoint.x, point.x), Swift.min(minPoint.y, point.y), Swift.min(minPoint.z, point.z)
                )
                maxPoint = Position(
                    Swift.max(maxPoint.x, point.x), Swift.max(maxPoint.y, point.y), Swift.max(maxPoint.z, point.z)
                )
            }
        }
        let fanCount = packet.flatVertices.count / 3 - fanStart
        guard fanCount > 0 else { return }
        packet.commands.append(DrawCommand(
            kind: .pathStencil, vertexStart: fanStart, vertexCount: fanCount, uniformOffset: slot
        ))

        // Pass B: cover quad over the path bounds (also clears the stencil bits).
        let coverStart = packet.flatVertices.count / 3
        let z = (minPoint.z + maxPoint.z) / 2
        let corners = [
            Position(minPoint.x, minPoint.y, z),
            Position(maxPoint.x, minPoint.y, z),
            Position(maxPoint.x, maxPoint.y, z),
            Position(minPoint.x, minPoint.y, z),
            Position(maxPoint.x, maxPoint.y, z),
            Position(minPoint.x, maxPoint.y, z),
        ]
        for corner in corners {
            appendFlat(corner, into: &packet)
        }
        packet.commands.append(DrawCommand(
            kind: .pathCover, vertexStart: coverStart, vertexCount: 6, uniformOffset: slot
        ))
    }

    private static func appendStroke(_ path: PathPrimitive, color: Color, into packet: inout FramePacket) {
        let slot = appendUniformSlot(model: .identity, color: color, into: &packet)
        let halfWidth = max(path.style.strokeWidth, 0.001) / 2

        // Count segments across all contours so strokeProgress caps globally
        // in draw order (the Write/draw reveal contract).
        var totalSegments = 0
        for contour in path.contours where contour.points.count >= 2 {
            totalSegments += contour.points.count - 1 + (contour.isClosed ? 1 : 0)
        }
        guard totalSegments > 0 else { return }
        let drawnSegments = path.strokeProgress >= 0.9999
            ? totalSegments
            : Int((Real(totalSegments) * min(max(path.strokeProgress, 0), 1)).rounded(.down))
        guard drawnSegments > 0 else { return }

        let start = packet.flatVertices.count / 3
        var emitted = 0
        outer: for contour in path.contours where contour.points.count >= 2 {
            let points = contour.points
            let segmentCount = points.count - 1 + (contour.isClosed ? 1 : 0)
            for segment in 0..<segmentCount {
                if emitted >= drawnSegments { break outer }
                let a = points[segment]
                let b = points[(segment + 1) % points.count]
                appendStrokeQuad(from: a, to: b, halfWidth: halfWidth, into: &packet)
                emitted += 1
            }
        }
        let count = packet.flatVertices.count / 3 - start
        packet.commands.append(DrawCommand(
            kind: .stroke, vertexStart: start, vertexCount: count, uniformOffset: slot
        ))
    }

    private static func appendStrokeQuad(
        from a: Position, to b: Position, halfWidth: Real, into packet: inout FramePacket
    ) {
        let delta = SIMD2<Real>(b.x - a.x, b.y - a.y)
        let length = (delta.x * delta.x + delta.y * delta.y).squareRoot()
        guard length > 1e-7 else { return }
        let dir = delta / length
        let normal = SIMD2<Real>(-dir.y, dir.x) * halfWidth
        // Square caps: extend both ends by halfWidth so adjacent quads seal joints.
        let cap = dir * halfWidth
        let a2 = SIMD2<Real>(a.x, a.y) - cap
        let b2 = SIMD2<Real>(b.x, b.y) + cap

        let v0 = Position(a2.x - normal.x, a2.y - normal.y, a.z)
        let v1 = Position(a2.x + normal.x, a2.y + normal.y, a.z)
        let v2 = Position(b2.x - normal.x, b2.y - normal.y, b.z)
        let v3 = Position(b2.x + normal.x, b2.y + normal.y, b.z)

        appendFlat(v0, into: &packet)
        appendFlat(v1, into: &packet)
        appendFlat(v2, into: &packet)
        appendFlat(v1, into: &packet)
        appendFlat(v3, into: &packet)
        appendFlat(v2, into: &packet)
    }

    private static func appendFlat(_ point: Position, into packet: inout FramePacket) {
        packet.flatVertices.append(Float32(point.x))
        packet.flatVertices.append(Float32(point.y))
        packet.flatVertices.append(Float32(point.z))
    }
}
#endif
