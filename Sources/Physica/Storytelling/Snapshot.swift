// SceneSnapshot — the renderer-facing flattening of a scene. Core stays headless;
// any RenderBackend (WebGPU on wasm, mocks in tests) consumes these value types.

/// Scene backdrop: a flat clear color, or a blackboard slate whose procedural
/// smudge-and-dust texture the renderer paints as a fullscreen pass behind
/// everything (`scene.background = .blackboard`).
import PhysicaFoundation
import PhysicaTypesetting

public enum SceneBackground: Sendable, Equatable {
    case color(Color)
    case blackboard(tint: Color)

    /// Classic deep-green slate.
    public static var blackboard: SceneBackground { .blackboard(tint: Color(hex: 0x1C2A24)) }

    /// The clear color (the blackboard texture brightens up from this base).
    public var baseColor: Color {
        switch self {
        case .color(let color): return color
        case .blackboard(let tint): return tint
        }
    }
}

public struct PathStyle: Sendable, Equatable {
    /// nil → no fill pass.
    public var fill: Color?
    /// nil → no stroke pass.
    public var stroke: Color?
    public var strokeWidth: Real
    public var cap: StrokeCap
    public var texture: PathTexture
    /// Entity world position — seeds chalk/pencil noise so the grain rides
    /// the entity instead of staying pinned to world space while it moves.
    public var textureSeed: SIMD2<Real>
    /// Neon tube: wide translucent glow pass under a whitened core stroke.
    public var neon: Bool

    public init(
        fill: Color?, stroke: Color?, strokeWidth: Real, cap: StrokeCap = .square,
        texture: PathTexture = .flat, textureSeed: SIMD2<Real> = .zero, neon: Bool = false
    ) {
        self.fill = fill
        self.stroke = stroke
        self.strokeWidth = strokeWidth
        self.cap = cap
        self.texture = texture
        self.textureSeed = textureSeed
        self.neon = neon
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
    /// 0...1 — tail trim; only strokeStart...strokeProgress is stroked.
    public var strokeStart: Real = 0
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
    public var shading: Shading = .lambert

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

/// Which interaction a debug-overlay label is flagging. The Option+Shift
/// overlay colors labels by this instead of spelling the kind out in text.
public enum InteractionKind: String, Sendable, Equatable {
    case drag, drop, tap, doubleClick, hover
}

/// Index labels shown while Shift is held.
public struct DebugLabel: Sendable, Equatable {
    public var text: String
    public var worldPosition: Position
    /// Set on the interactive (Option+Shift) overlay so the renderer can color
    /// the label by interaction kind; nil for the plain index overlay.
    public var interaction: InteractionKind?

    public init(text: String, worldPosition: Position, interaction: InteractionKind? = nil) {
        self.text = text
        self.worldPosition = worldPosition
        self.interaction = interaction
    }
}

public struct CameraState: Sendable {
    public var view: Matrix4
    public var projection: Matrix4
    public var position: Position
}

public struct SceneSnapshot: Sendable {
    public var primitives: [RenderPrimitive]
    public var camera: CameraState
    public var background: SceneBackground
    /// The camera's visible rect at z = 0 (the blackboard pass covers it).
    public var frame: Bounds
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

        // strokeWidth is normalized (1 = 10% of the frame's longest side);
        // primitives carry resolved world units — the renderer stays dumb.
        let frame = frameBounds
        var strokeScale = 0.1 * Swift.max(frame.size.x, frame.size.y)
        if strokeScale <= 0 { strokeScale = 1 }

        for root in entities {
            collect(entity: root, strokeScale: strokeScale, into: &primitives)
        }

        return SceneSnapshot(
            primitives: primitives,
            camera: CameraState(
                view: camera.viewMatrix(),
                projection: camera.projectionMatrix(aspect: viewportAspect),
                position: camera.transform.position
            ),
            background: background,
            frame: frameBounds,
            time: timeline.currentTime,
            // Same source as the live overlay (one centered label per top-level
            // entity), so snapshot tests see exactly what the DOM overlay draws.
            debugLabels: includeDebugLabels ? collectDebugLabels() : []
        )
    }

    private func collect(
        entity: Entity,
        strokeScale: Real,
        into primitives: inout [RenderPrimitive]
    ) {
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
                        strokeWidth: min(max(style.strokeWidth, 0), 1) * strokeScale,
                        cap: style.cap,
                        texture: style.texture,
                        textureSeed: SIMD2(world.position.x, world.position.y),
                        neon: style.neon
                    ),
                    strokeProgress: pathComponent.strokeProgress,
                    strokeStart: pathComponent.strokeStart,
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
                opacity: model.opacity,
                shading: model.shading
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
                // Glyph-slice overrides (`title[0..<3].color/fade`) win
                // over the entity style, per glyph.
                let glyphOpacity = opacity * Float(glyph.opacity)
                let fillColor = glyph.color ?? style.color
                let strokeColor = glyph.color ?? style.strokeColor ?? style.color
                primitives.append(.path(PathPrimitive(
                    contours: contours,
                    style: PathStyle(
                        fill: style.isFilled ? fillColor.with(opacity: glyphOpacity) : nil,
                        stroke: strokeColor.with(opacity: glyphOpacity),
                        strokeWidth: min(max(style.strokeWidth, 0), 1) * strokeScale,
                        cap: style.cap,
                        texture: style.texture,
                        textureSeed: SIMD2(world.position.x, world.position.y)
                    ),
                    strokeProgress: factors.stroke,
                    fillOpacityFactor: factors.fill
                )))
            }
        }

        if let group = entity as? Group {
            for child in group.children {
                collect(entity: child, strokeScale: strokeScale, into: &primitives)
            }
        }
    }
}
