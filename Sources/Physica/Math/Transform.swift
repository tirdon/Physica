// Transform — position/orientation/scale, the pure value under every entity's
// TransformComponent (which lives in the kernel).

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
