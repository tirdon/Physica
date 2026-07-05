// GeometryUploader — turns a SceneSnapshot into flat GPU-ready arrays + a draw list.
// Per-frame rebuild: one flat-vertex stream, one mesh stream, one uniform block.

import PhysicaFoundation
import PhysicaAlgebra
import PhysicaTypesetting
import PhysicaKernel
import PhysicaCharts
import PhysicaPhysics
import PhysicaEquationGame

#if os(WASI)

struct DrawCommand {
    enum Kind {
        case pathStencil
        case pathCover
        case stroke
        case mesh
        /// Inverted-hull toon outline: same index range as its mesh, own slot.
        case meshOutline
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
    static func pack(_ snapshot: borrowing SceneSnapshot) -> FramePacket {
        var packet = FramePacket()

        // Blackboard backdrop first: a fullscreen flat quad (depth off) that
        // meshes overdraw and paths paint over.
        if case .blackboard(let tint) = snapshot.background {
            appendBlackboard(tint: tint, frame: snapshot.frame, into: &packet)
        }

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

    /// `params` is the shader's free vec4: paths use x = texture mode
    /// (0 flat / 1 chalk / 2 pencil / 3 blackboard backdrop), yz = grain
    /// seed (entity position — anchors the noise to the entity); meshes use
    /// x = shading (0 lambert / 1 toon), y = toon bands, z = outline
    /// thickness (vs_outline inflate).
    private static func appendUniformSlot(
        model: Matrix4, color: Color, params: [Float32] = [0, 0, 0, 0],
        into packet: inout FramePacket
    ) -> Int {
        let offset = packet.uniforms.count * 4
        packet.uniforms.append(contentsOf: model.floatArray)
        packet.uniforms.append(contentsOf: [color.r, color.g, color.b, color.a])
        packet.uniforms.append(contentsOf: params)
        let pad = FramePacket.uniformSlotFloats - 24
        packet.uniforms.append(contentsOf: [Float32](repeating: 0, count: pad))
        return offset
    }

    private static func params(for style: PathStyle) -> [Float32] {
        let mode: Float32
        switch style.texture {
        case .flat: return [0, 0, 0, 0]
        case .chalk: mode = 1
        case .pencil: mode = 2
        }
        // yz seed the grain with the entity position so the noise rides
        // the entity (world − seed in the shader) instead of staying
        // world-pinned while it moves.
        return [mode, Float32(style.textureSeed.x), Float32(style.textureSeed.y), 0]
    }

    // MARK: Background

    /// Fullscreen quad through the flat color pipeline with params.x = 3
    /// (blackboard grain). The frame is the camera's visible rect at z = 0;
    /// 8% overscan so live-resize aspect drift never exposes the clear edge.
    private static func appendBlackboard(tint: Color, frame: Bounds, into packet: inout FramePacket) {
        let slot = appendUniformSlot(model: .identity, color: tint, params: [3, 0, 0, 0], into: &packet)
        let center = frame.center
        let halfW = max(frame.size.x, 1) * 0.54
        let halfH = max(frame.size.y, 1) * 0.54
        let start = packet.flatVertices.count / 3
        let corners = [
            Position(center.x - halfW, center.y - halfH, 0),
            Position(center.x + halfW, center.y - halfH, 0),
            Position(center.x + halfW, center.y + halfH, 0),
            Position(center.x - halfW, center.y - halfH, 0),
            Position(center.x + halfW, center.y + halfH, 0),
            Position(center.x - halfW, center.y + halfH, 0),
        ]
        for corner in corners {
            appendFlat(corner, into: &packet)
        }
        packet.commands.append(DrawCommand(
            kind: .stroke, vertexStart: start, vertexCount: 6, uniformOffset: slot
        ))
    }

    // MARK: Meshes

    private static func appendMesh(_ mesh: borrowing MeshDraw, into packet: inout FramePacket) {
        var shadingParams: [Float32] = [0, 0, 0, 0]
        var outline: Real = 0
        if case .toon(let bands, let outlineWidth) = mesh.shading {
            shadingParams = [1, Float32(max(bands, 2)), 0, 0]
            outline = outlineWidth
        }
        let opaqueColor = mesh.color.with(opacity: Float(mesh.opacity))
        let slot = appendUniformSlot(
            model: mesh.model, color: opaqueColor, params: shadingParams, into: &packet
        )
        let baseVertex = packet.meshVertices.count / 6
        packet.meshVertices.reserveCapacity(packet.meshVertices.count + mesh.positions.count * 6)
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

        // Outline first; the base mesh's nearer front faces depth-win inside,
        // leaving the inflated hull visible only as a silhouette ring.
        if outline > 0 {
            let outlineSlot = appendUniformSlot(
                model: mesh.model,
                color: Color(hex: 0x14141A).with(opacity: Float(mesh.opacity)),
                params: [0, 0, Float32(outline), 0],
                into: &packet
            )
            packet.commands.append(DrawCommand(
                kind: .meshOutline,
                indexStart: indexStart,
                indexCount: mesh.indices.count,
                baseVertex: baseVertex,
                uniformOffset: outlineSlot
            ))
        }
        packet.commands.append(DrawCommand(
            kind: .mesh,
            indexStart: indexStart,
            indexCount: mesh.indices.count,
            baseVertex: baseVertex,
            uniformOffset: slot
        ))
    }

    // MARK: Paths

    private static func appendPath(_ path: borrowing PathPrimitive, into packet: inout FramePacket) {
        if let fill = path.style.fill {
            let color = fill.with(opacity: Float(path.fillOpacityFactor))
            if color.a > 0.001 {
                appendFill(path, color: color, into: &packet)
            }
        }
        if let stroke = path.style.stroke, path.strokeProgress - path.strokeStart > 0.0001 {
            appendStroke(path, color: stroke, into: &packet)
        }
    }

    private static func appendFill(_ path: borrowing PathPrimitive, color: Color, into packet: inout FramePacket) {
        let slot = appendUniformSlot(
            model: .identity, color: color, params: params(for: path.style), into: &packet
        )

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

    private static func appendStroke(_ path: borrowing PathPrimitive, color: Color, into packet: inout FramePacket) {
        let halfWidth = max(path.style.strokeWidth, 0.001) / 2

        // Count segments across all contours so the trim window maps globally
        // in draw order (the Write/draw reveal contract).
        var totalSegments = 0
        for contour in path.contours where contour.points.count >= 2 {
            totalSegments += contour.points.count - 1 + (contour.isClosed ? 1 : 0)
        }
        guard totalSegments > 0 else { return }

        // Continuous trim window [strokeStart, strokeProgress]: whole quads
        // plus fractional ends on the boundary segments, so draw grows, erase
        // retracts, and the highlight tail chases smoothly along a side.
        // Integer-only capping pops whole segments — invisible on a flattened
        // circle (~100 segments), glaring on a 3-segment triangle.
        let head = min(max(path.strokeProgress, 0), 1)
        let tail = min(max(path.strokeStart, 0), head)
        var endExact = Real(totalSegments) * head
        var startExact = Real(totalSegments) * tail
        if head >= 0.9999 { endExact = Real(totalSegments) }
        if tail <= 0.0001 { startExact = 0 }
        guard endExact - startExact > 1e-4 else { return }

        let cap = path.style.cap
        func emitQuads(halfWidth: Real) -> (start: Int, count: Int) {
            let start = packet.flatVertices.count / 3
            var segmentIndex = 0
            outer: for contour in path.contours where contour.points.count >= 2 {
                let points = contour.points
                let segmentCount = points.count - 1 + (contour.isClosed ? 1 : 0)
                var runActive = false  // round: disc at a run's first point, then at every end
                for segment in 0..<segmentCount {
                    let lo = startExact - Real(segmentIndex)
                    let hi = endExact - Real(segmentIndex)
                    segmentIndex += 1
                    if hi <= 1e-4 { break outer }
                    if lo >= 1 { continue }
                    let from = max(lo, 0)
                    let to = min(hi, 1)
                    guard to - from > 1e-4 else { continue }
                    let a = points[segment]
                    let b = points[(segment + 1) % points.count]
                    let quadStart = a + (b - a) * from
                    let quadEnd = a + (b - a) * to
                    appendStrokeQuad(
                        from: quadStart, to: quadEnd, halfWidth: halfWidth,
                        extendEnds: cap == .square, into: &packet
                    )
                    if cap == .round {
                        if !runActive {
                            appendDisc(center: quadStart, radius: halfWidth, into: &packet)
                        }
                        appendDisc(center: quadEnd, radius: halfWidth, into: &packet)
                    }
                    runActive = true
                }
            }
            return (start, packet.flatVertices.count / 3 - start)
        }

        if path.style.neon {
            // Neon tube: stacked translucent halos approximate a soft glow
            // falloff (flat quads can't gradient across the stroke), then a
            // hot, slightly whitened core — all over the same trim window.
            let halos: [(width: Real, alpha: Float32)] = [(4.5, 0.10), (2.4, 0.22)]
            for halo in halos {
                let slot = appendUniformSlot(
                    model: .identity, color: color.with(opacity: halo.alpha), into: &packet
                )
                let range = emitQuads(halfWidth: halfWidth * halo.width)
                if range.count > 0 {
                    packet.commands.append(DrawCommand(
                        kind: .stroke, vertexStart: range.start, vertexCount: range.count,
                        uniformOffset: slot
                    ))
                }
            }
            var coreColor = Color.lerp(color, .white, 0.35)
            coreColor.a = color.a
            let coreSlot = appendUniformSlot(model: .identity, color: coreColor, into: &packet)
            let core = emitQuads(halfWidth: halfWidth)
            if core.count > 0 {
                packet.commands.append(DrawCommand(
                    kind: .stroke, vertexStart: core.start, vertexCount: core.count,
                    uniformOffset: coreSlot
                ))
            }
            return
        }

        let slot = appendUniformSlot(
            model: .identity, color: color, params: params(for: path.style), into: &packet
        )
        let range = emitQuads(halfWidth: halfWidth)
        guard range.count > 0 else { return }
        packet.commands.append(DrawCommand(
            kind: .stroke, vertexStart: range.start, vertexCount: range.count, uniformOffset: slot
        ))
    }

    private static func appendStrokeQuad(
        from a: Position, to b: Position, halfWidth: Real, extendEnds: Bool,
        into packet: inout FramePacket
    ) {
        let delta = SIMD2<Real>(b.x - a.x, b.y - a.y)
        let length = (delta.x * delta.x + delta.y * delta.y).squareRoot()
        guard length > 1e-7 else { return }
        let dir = delta / length
        let normal = SIMD2<Real>(-dir.y, dir.x) * halfWidth
        // Square caps extend both ends by halfWidth so adjacent quads seal
        // joints; butt/round leave the ends exact (round seals with discs).
        let cap = extendEnds ? dir * halfWidth : SIMD2<Real>(0, 0)
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

    /// Round-cap/joint disc: a small triangle fan around `center`.
    private static func appendDisc(center: Position, radius: Real, into packet: inout FramePacket) {
        let segments = 10
        var previous = SIMD2<Real>(center.x + radius, center.y)
        for index in 1...segments {
            let angle = Real(index) / Real(segments) * 2 * Real.pi
            let next = SIMD2<Real>(
                center.x + radius * Real.cos(angle),
                center.y + radius * Real.sin(angle)
            )
            appendFlat(center, into: &packet)
            appendFlat(Position(previous.x, previous.y, center.z), into: &packet)
            appendFlat(Position(next.x, next.y, center.z), into: &packet)
            previous = next
        }
    }

    private static func appendFlat(_ point: Position, into packet: inout FramePacket) {
        packet.flatVertices.append(Float32(point.x))
        packet.flatVertices.append(Float32(point.y))
        packet.flatVertices.append(Float32(point.z))
    }
}
#endif
