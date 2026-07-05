// Camera — orthographic by default (Manim-style 2D), perspective for 3D physics.

import PhysicaFoundation
import PhysicaTypesetting

public struct Camera: Sendable {
    public enum Projection: Sendable, Equatable {
        /// Longest visible side is `extent`; the short side follows the aspect:
        /// w > h → extent × extent/aspect, w < h → extent·aspect × extent.
        case orthographicFit(extent: Real)
        /// Fixed visible world height; width follows the viewport aspect.
        case orthographic(height: Real)
        case perspective(fovYDegrees: Real)
    }

    public var transform: Transform
    public var projection: Projection
    public var near: Real
    public var far: Real

    public init(
        transform: Transform = Transform(position: Position(0, 0, 10)),
        projection: Projection = .orthographicFit(extent: 10),
        near: Real = 0.1,
        far: Real = 100
    ) {
        self.transform = transform
        self.projection = projection
        self.near = near
        self.far = far
    }

    /// World → camera space (camera has no scale).
    public func viewMatrix() -> Matrix4 {
        Matrix4.trs(translation: transform.position, rotation: transform.orientation, scale: SIMD3(1, 1, 1))
            .rigidInverse
    }

    public func projectionMatrix(aspect: Real) -> Matrix4 {
        switch projection {
        case .orthographicFit(let extent):
            let halfH = Camera.fitHeight(extent: extent, aspect: aspect) / 2
            let halfW = halfH * aspect
            return .orthographic(left: -halfW, right: halfW, bottom: -halfH, top: halfH, near: near, far: far)
        case .orthographic(let height):
            let halfH = height / 2
            let halfW = halfH * aspect
            return .orthographic(left: -halfW, right: halfW, bottom: -halfH, top: halfH, near: near, far: far)
        case .perspective(let fov):
            return .perspective(fovYRadians: fov * .pi / 180, aspect: aspect, near: near, far: far)
        }
    }

    /// Height of a fit frame: the longest side equals `extent`.
    static func fitHeight(extent: Real, aspect: Real) -> Real {
        aspect >= 1 ? extent / aspect : extent
    }

    /// Visible world rect on the plane z = `z` — the frame `move(to: Unit)` targets.
    public func visibleRect(atZ z: Real = 0, aspect: Real) -> Bounds {
        let height: Real
        switch projection {
        case .orthographicFit(let extent):
            height = Camera.fitHeight(extent: extent, aspect: aspect)
        case .orthographic(let h):
            height = h
        case .perspective(let fov):
            let distance = Swift.abs(transform.position.z - z)
            height = 2 * distance * Real.tan(fov * .pi / 180 / 2)
        }
        let size = Position(height * aspect, height, 0)
        let center = Position(transform.position.x, transform.position.y, z)
        return Bounds(center: center, size: size)
    }
}
