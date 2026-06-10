// SceneSnapshot — the renderer-facing flattening of a scene. Core stays headless;
// any RenderBackend (WebGPU on wasm, mocks in tests) consumes these value types.

public struct PathStyle: Sendable, Equatable {
    /// nil → no fill pass.
    public var fill: Color?
    /// nil → no stroke pass.
    public var stroke: Color?
    public var strokeWidth: Real

    public init(fill: Color?, stroke: Color?, strokeWidth: Real) {
        self.fill = fill
        self.stroke = stroke
        self.strokeWidth = strokeWidth
    }
}

/// A path flattened to world-space polylines, ready for stencil-fill + stroke.
public struct PathPrimitive: Sendable {
    public struct Contour: Sendable {
        public var points: [Position]
        public var isClosed: Bool
    }

    public var contours: [Contour]
    public var style: PathStyle
    /// 0...1 — stroke reveal cap (Write/draw animations).
    public var strokeProgress: Real
    /// 0...1 — extra fill alpha factor (Write fade-in).
    public var fillOpacityFactor: Real

    public var debugString: String {
        let counts = contours.map { "\($0.points.count)\($0.isClosed ? "c" : "o")" }
        var flags: [String] = []
        if style.fill != nil { flags.append("fill") }
        if style.stroke != nil { flags.append("stroke") }
        return "path[\(counts.joined(separator: ","))] \(flags.joined(separator: "+"))"
    }
}

public struct MeshDraw: Sendable {
    public var positions: [Position]
    public var normals: [Position]
    public var indices: [UInt32]
    public var model: Matrix4
    public var color: Color
    public var opacity: Real

    public var debugString: String {
        "mesh[v\(positions.count) i\(indices.count)]"
    }
}

public enum RenderPrimitive: Sendable {
    case path(PathPrimitive)
    case mesh(MeshDraw)

    public var debugString: String {
        switch self {
        case .path(let path): return path.debugString
        case .mesh(let mesh): return mesh.debugString
        }
    }
}

/// Index labels shown while Shift is held.
public struct DebugLabel: Sendable, Equatable {
    public var text: String
    public var worldPosition: Position
}

public struct CameraState: Sendable {
    public var view: Matrix4
    public var projection: Matrix4
    public var position: Position
}

public struct SceneSnapshot: Sendable {
    public var primitives: [RenderPrimitive]
    public var camera: CameraState
    public var background: Color
    public var time: TimeInterval
    public var debugLabels: [DebugLabel]

    public var debugString: String {
        let lines = primitives.map { "  " + $0.debugString }
        return "snapshot t=\(fmt(time, decimals: 2)) primitives(\(primitives.count)):\n" + lines.joined(separator: "\n")
    }
}

@MainActor
public protocol RenderBackend: AnyObject {
    /// Viewport aspect ratio (width / height) the scene should project for.
    var aspectRatio: Real { get }
    func render(_ snapshot: SceneSnapshot)
}

// MARK: - Snapshot production

extension Scene {
    /// Flattens the visible entity tree to renderer-ready primitives, painter's order.
    public func snapshot(includeDebugLabels: Bool = false) -> SceneSnapshot {
        var primitives: [RenderPrimitive] = []
        var labels: [DebugLabel]? = includeDebugLabels ? [] : nil

        for (index, root) in entities.enumerated() {
            collect(
                entity: root,
                indexPath: "\(index)",
                into: &primitives,
                labels: &labels
            )
        }

        return SceneSnapshot(
            primitives: primitives,
            camera: CameraState(
                view: camera.viewMatrix(),
                projection: camera.projectionMatrix(aspect: viewportAspect),
                position: camera.transform.position
            ),
            background: background,
            time: timeline.currentTime,
            debugLabels: labels ?? []
        )
    }

    private func collect(
        entity: Entity,
        indexPath: String,
        into primitives: inout [RenderPrimitive],
        labels: inout [DebugLabel]?
    ) {
        labels?.append(DebugLabel(text: indexPath, worldPosition: entity.center))

        if let pathComponent = entity.components[PathComponent.self],
           !pathComponent.path.isEmpty {
            let style = entity.components[RenderStyleComponent.self] ?? RenderStyleComponent()
            let world = entity.worldTransform
            let contours = pathComponent.path.flattened().map { contour in
                PathPrimitive.Contour(
                    points: contour.points.map { world.applying(to: Position($0.x, $0.y, 0)) },
                    isClosed: contour.isClosed
                )
            }
            if !contours.isEmpty {
                let opacity = Float(style.opacity)
                primitives.append(.path(PathPrimitive(
                    contours: contours,
                    style: PathStyle(
                        fill: style.isFilled ? style.color.with(opacity: opacity) : nil,
                        stroke: style.strokeColor.map { $0.with(opacity: opacity) },
                        strokeWidth: style.strokeWidth
                    ),
                    strokeProgress: pathComponent.strokeProgress,
                    fillOpacityFactor: pathComponent.fillOpacityFactor
                )))
            }
        }

        if let model = entity.components[ModelComponent.self], !model.mesh.positions.isEmpty {
            primitives.append(.mesh(MeshDraw(
                positions: model.mesh.positions,
                normals: model.mesh.normals,
                indices: model.mesh.indices,
                model: entity.worldTransform.matrix,
                color: model.color,
                opacity: model.opacity
            )))
        }

        if let text = entity.components[TextComponent.self], !text.glyphs.isEmpty {
            let style = entity.components[RenderStyleComponent.self] ?? RenderStyleComponent()
            let world = entity.worldTransform
            let opacity = Float(style.opacity)
            let count = text.glyphs.count

            for (glyphIndex, glyph) in text.glyphs.enumerated() {
                let factors = TextComponent.glyphFactors(
                    writeProgress: text.writeProgress,
                    index: glyphIndex,
                    count: count,
                    lagRatio: text.lagRatio
                )
                guard factors.stroke > 0.0001 else { continue }

                let localPath = glyph.path.translated(by: glyph.offset).scaled(by: text.fontSize)
                let contours = localPath.flattened().map { contour in
                    PathPrimitive.Contour(
                        points: contour.points.map { world.applying(to: Position($0.x, $0.y, 0)) },
                        isClosed: contour.isClosed
                    )
                }
                guard !contours.isEmpty else { continue }
                primitives.append(.path(PathPrimitive(
                    contours: contours,
                    style: PathStyle(
                        fill: style.isFilled ? style.color.with(opacity: opacity) : nil,
                        stroke: (style.strokeColor ?? style.color).with(opacity: opacity),
                        strokeWidth: style.strokeWidth
                    ),
                    strokeProgress: factors.stroke,
                    fillOpacityFactor: factors.fill
                )))
            }
        }

        if let group = entity as? Group {
            for (childIndex, child) in group.children.enumerated() {
                collect(
                    entity: child,
                    indexPath: "\(indexPath).\(childIndex)",
                    into: &primitives,
                    labels: &labels
                )
            }
        }
    }
}
