// Core value types and built-in components shared by every entity kind.

// MARK: - Transform

public struct Transform: Sendable, Equatable, CustomDebugStringConvertible {
    public var position: Position
    public var orientation: Quaternion
    public var scale: SIMD3<Real>

    public static let identity = Transform()

    public init(
        position: Position = .zero,
        orientation: Quaternion = .identity,
        scale: SIMD3<Real> = SIMD3(1, 1, 1)
    ) {
        self.position = position
        self.orientation = orientation
        self.scale = scale
    }

    public var matrix: Matrix4 {
        .trs(translation: position, rotation: orientation, scale: scale)
    }

    /// Parent ∘ child composition (applies child within parent's space).
    public func concatenating(_ child: Transform) -> Transform {
        Transform(
            position: position + orientation.rotate(scale * child.position),
            orientation: orientation * child.orientation,
            scale: scale * child.scale
        )
    }

    public func applying(to point: Position) -> Position {
        position + orientation.rotate(scale * point)
    }

    public var debugDescription: String {
        "pos\(fmt(position)) rot(\(fmt(orientation.x)), \(fmt(orientation.y)), \(fmt(orientation.z)), \(fmt(orientation.w))) scale\(fmt(scale))"
    }
}

extension Transform: Interpolatable {
    public static func lerp(_ from: Transform, _ to: Transform, _ t: Real) -> Transform {
        Transform(
            position: .lerp(from.position, to.position, t),
            orientation: .slerp(from.orientation, to.orientation, t),
            scale: .lerp(from.scale, to.scale, t)
        )
    }
}

// MARK: - Bounds

/// Axis-aligned bounding box. `empty` unions as a no-op.
public struct Bounds: Sendable, Equatable {
    public var min: Position
    public var max: Position

    public static let empty = Bounds(min: Position(.infinity, .infinity, .infinity),
                                     max: Position(-.infinity, -.infinity, -.infinity))

    public init(min: Position, max: Position) {
        self.min = min
        self.max = max
    }

    public init(center: Position, size: Position) {
        self.min = center - size / 2
        self.max = center + size / 2
    }

    public var isEmpty: Bool { min.x > max.x }
    public var center: Position { isEmpty ? .zero : (min + max) / 2 }
    public var size: Position { isEmpty ? .zero : max - min }

    /// The 8 box corners (every min/max combination); `empty` has none.
    public var corners: [Position] {
        if isEmpty { return [] }
        var result: [Position] = []
        result.reserveCapacity(8)
        for cx in [min.x, max.x] {
            for cy in [min.y, max.y] {
                for cz in [min.z, max.z] {
                    result.append(Position(cx, cy, cz))
                }
            }
        }
        return result
    }

    public func union(_ other: Bounds) -> Bounds {
        if isEmpty { return other }
        if other.isEmpty { return self }
        return Bounds(
            min: Position(Swift.min(min.x, other.min.x), Swift.min(min.y, other.min.y), Swift.min(min.z, other.min.z)),
            max: Position(Swift.max(max.x, other.max.x), Swift.max(max.y, other.max.y), Swift.max(max.z, other.max.z))
        )
    }

    public func union(_ point: Position) -> Bounds {
        union(Bounds(min: point, max: point))
    }

    /// Bounds of the 8 transformed corners.
    public func transformed(by transform: Transform) -> Bounds {
        if isEmpty { return Bounds(min: transform.position, max: transform.position) }
        var result = Bounds.empty
        for cx in [min.x, max.x] {
            for cy in [min.y, max.y] {
                for cz in [min.z, max.z] {
                    result = result.union(transform.applying(to: Position(cx, cy, cz)))
                }
            }
        }
        return result
    }

    public func contains(_ point: Position) -> Bool {
        !isEmpty
            && point.x >= min.x && point.x <= max.x
            && point.y >= min.y && point.y <= max.y
            && point.z >= min.z && point.z <= max.z
    }
}

// MARK: - Built-in components

public struct TransformComponent: Component {
    public var transform: Transform

    public init(transform: Transform = .identity) {
        self.transform = transform
    }

    public var debugString: String { transform.debugDescription }
}

/// Procedural grain the renderer applies to a path's fill and stroke.
/// World-anchored noise — it sticks to the geometry, not the screen.
public enum PathTexture: Sendable, Equatable {
    case flat
    /// Coarse board grain with voids, like chalk on slate.
    case chalk
    /// Fine diagonal graphite striations.
    case pencil
}

/// Stroke end-cap (and joint-sealing) style.
public enum StrokeCap: Sendable, Equatable {
    /// Flat end exactly at the path end; shallow joint gaps may show.
    case butt
    /// Ends extended by half the stroke width — seals joints (the default).
    case square
    /// Discs at ends and joints — best where line ends are visible
    /// (neon highlight, open Lines, trimmed reveals).
    case round
}

/// Fill/stroke styling consumed by the snapshot pass.
public struct RenderStyleComponent: Component {
    public var color: Color
    public var strokeColor: Color?
    /// Normalized 0...1: 1 = 10% of the frame's longest side. At the default
    /// fit-10 camera that is exactly 1 world unit, so values read like world
    /// units there — but strokes scale with the frame if the camera changes.
    public var strokeWidth: Real
    public var cap: StrokeCap
    public var isFilled: Bool
    public var opacity: Real
    public var texture: PathTexture
    /// Neon tube look: the renderer adds a wide translucent glow pass under
    /// the stroke and whitens its core (highlight borders).
    public var neon: Bool

    public init(
        color: Color = .white,
        strokeColor: Color? = nil,
        strokeWidth: Real = 0.04,
        cap: StrokeCap = .square,
        isFilled: Bool = true,
        opacity: Real = 1,
        texture: PathTexture = .flat,
        neon: Bool = false
    ) {
        self.color = color
        self.strokeColor = strokeColor
        self.strokeWidth = strokeWidth
        self.cap = cap
        self.isFilled = isFilled
        self.opacity = opacity
        self.texture = texture
        self.neon = neon
    }

    public var debugString: String {
        "style(\(color.debugDescription), stroke: \(strokeColor?.debugDescription ?? "none"), opacity: \(fmt(opacity, decimals: 2)))"
    }
}

@MainActor
public extension Entity {
    /// `title.textured(.chalk)` / `shape.textured(.pencil)` — chainable; applies
    /// to anything the snapshot turns into path primitives (shapes, text, math).
    @discardableResult
    func textured(_ texture: PathTexture) -> Self {
        var style = components[RenderStyleComponent.self] ?? RenderStyleComponent()
        style.texture = texture
        components[RenderStyleComponent.self] = style
        return self
    }
}
