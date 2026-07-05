// Column-major 4×4 matrix. Projection matrices target WebGPU clip space (z ∈ [0, 1]).

public struct Matrix4: Sendable, Equatable {
    public var c0: SIMD4<Real>
    public var c1: SIMD4<Real>
    public var c2: SIMD4<Real>
    public var c3: SIMD4<Real>

    public init(_ c0: SIMD4<Real>, _ c1: SIMD4<Real>, _ c2: SIMD4<Real>, _ c3: SIMD4<Real>) {
        self.c0 = c0
        self.c1 = c1
        self.c2 = c2
        self.c3 = c3
    }

    public static let identity = Matrix4(
        SIMD4(1, 0, 0, 0),
        SIMD4(0, 1, 0, 0),
        SIMD4(0, 0, 1, 0),
        SIMD4(0, 0, 0, 1)
    )

    public static func * (l: Matrix4, r: Matrix4) -> Matrix4 {
        Matrix4(l.transform(r.c0), l.transform(r.c1), l.transform(r.c2), l.transform(r.c3))
    }

    public func transform(_ v: SIMD4<Real>) -> SIMD4<Real> {
        c0 * v.x + c1 * v.y + c2 * v.z + c3 * v.w
    }

    /// Transforms a point (w = 1), without perspective divide.
    public func transformPoint(_ p: Position) -> Position {
        let v = transform(SIMD4(p.x, p.y, p.z, 1))
        return Position(v.x, v.y, v.z)
    }

    /// Transforms a point and applies the perspective divide.
    public func project(_ p: Position) -> Position {
        let v = transform(SIMD4(p.x, p.y, p.z, 1))
        let w = v.w == 0 ? Real(1) : v.w
        return Position(v.x / w, v.y / w, v.z / w)
    }

    /// Transforms a direction (w = 0).
    public func transformDirection(_ d: Position) -> Position {
        let v = transform(SIMD4(d.x, d.y, d.z, 0))
        return Position(v.x, v.y, v.z)
    }

    public static func translation(_ t: Position) -> Matrix4 {
        Matrix4(
            SIMD4(1, 0, 0, 0),
            SIMD4(0, 1, 0, 0),
            SIMD4(0, 0, 1, 0),
            SIMD4(t.x, t.y, t.z, 1)
        )
    }

    public static func scale(_ s: SIMD3<Real>) -> Matrix4 {
        Matrix4(
            SIMD4(s.x, 0, 0, 0),
            SIMD4(0, s.y, 0, 0),
            SIMD4(0, 0, s.z, 0),
            SIMD4(0, 0, 0, 1)
        )
    }

    /// Translation · Rotation · Scale.
    public static func trs(translation t: Position, rotation r: Quaternion, scale s: SIMD3<Real>) -> Matrix4 {
        Matrix4.translation(t) * r.matrix * Matrix4.scale(s)
    }

    /// Right-handed orthographic projection into WebGPU clip space.
    public static func orthographic(
        left: Real, right: Real, bottom: Real, top: Real, near: Real, far: Real
    ) -> Matrix4 {
        let rl = right - left
        let tb = top - bottom
        let nf = near - far
        return Matrix4(
            SIMD4(2 / rl, 0, 0, 0),
            SIMD4(0, 2 / tb, 0, 0),
            SIMD4(0, 0, 1 / nf, 0),
            SIMD4(-(right + left) / rl, -(top + bottom) / tb, near / nf, 1)
        )
    }

    /// Right-handed perspective projection into WebGPU clip space.
    public static func perspective(fovYRadians: Real, aspect: Real, near: Real, far: Real) -> Matrix4 {
        let ys = 1 / Real.tan(fovYRadians / 2)
        let xs = ys / aspect
        let nf = near - far
        return Matrix4(
            SIMD4(xs, 0, 0, 0),
            SIMD4(0, ys, 0, 0),
            SIMD4(0, 0, far / nf, -1),
            SIMD4(0, 0, near * far / nf, 0)
        )
    }

    public static func lookAt(eye: Position, target: Position, up: Position) -> Matrix4 {
        let forward = (target - eye).normalized          // camera looks along -z
        let right = forward.cross(up).normalized
        let trueUp = right.cross(forward)
        // Rows of the rotation part are the basis vectors; translation brings eye to origin.
        return Matrix4(
            SIMD4(right.x, trueUp.x, -forward.x, 0),
            SIMD4(right.y, trueUp.y, -forward.y, 0),
            SIMD4(right.z, trueUp.z, -forward.z, 0),
            SIMD4(-right.dot(eye), -trueUp.dot(eye), forward.dot(eye), 1)
        )
    }

    /// Inverse for matrices composed of rotation + translation only (no scale).
    public var rigidInverse: Matrix4 {
        // Transpose the 3×3 rotation block.
        let r0 = SIMD4(c0.x, c1.x, c2.x, 0 as Real)
        let r1 = SIMD4(c0.y, c1.y, c2.y, 0 as Real)
        let r2 = SIMD4(c0.z, c1.z, c2.z, 0 as Real)
        let t = Position(c3.x, c3.y, c3.z)
        let rt = Position(
            r0.x * t.x + r1.x * t.y + r2.x * t.z,
            r0.y * t.x + r1.y * t.y + r2.y * t.z,
            r0.z * t.x + r1.z * t.y + r2.z * t.z
        )
        return Matrix4(r0, r1, r2, SIMD4(-rt.x, -rt.y, -rt.z, 1))
    }

    /// Column-major Float32 layout for GPU upload.
    public var floatArray: [Float] {
        [
            Float(c0.x), Float(c0.y), Float(c0.z), Float(c0.w),
            Float(c1.x), Float(c1.y), Float(c1.z), Float(c1.w),
            Float(c2.x), Float(c2.y), Float(c2.z), Float(c2.w),
            Float(c3.x), Float(c3.y), Float(c3.z), Float(c3.w),
        ]
    }
}
