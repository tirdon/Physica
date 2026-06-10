// Hand-rolled quaternion over SIMD4 — Apple's simd module is unavailable on WASI.
// Storage convention: vector = (x, y, z, w) with w the scalar part.

public struct Quaternion: Sendable, Hashable {
    public var vector: SIMD4<Real>

    public static let identity = Quaternion(vector: SIMD4(0, 0, 0, 1))

    public init(vector: SIMD4<Real>) {
        self.vector = vector
    }

    public init(x: Real, y: Real, z: Real, w: Real) {
        self.vector = SIMD4(x, y, z, w)
    }

    /// Rotation of `angle` radians around `axis` (normalized internally).
    public init(angle: Real, axis: Position) {
        let a = axis.normalized
        let half = angle / 2
        let s = Real.sin(half)
        self.vector = SIMD4(a.x * s, a.y * s, a.z * s, Real.cos(half))
    }

    public var x: Real { vector.x }
    public var y: Real { vector.y }
    public var z: Real { vector.z }
    public var w: Real { vector.w }

    /// The imaginary (vector) part.
    public var imaginary: Position { Position(vector.x, vector.y, vector.z) }

    public var lengthValue: Real {
        (vector * vector).sum().squareRoot()
    }

    public var normalized: Quaternion {
        let l = lengthValue
        guard l > Real.ulpOfOne else { return .identity }
        return Quaternion(vector: vector / l)
    }

    public var conjugate: Quaternion {
        Quaternion(vector: SIMD4(-vector.x, -vector.y, -vector.z, vector.w))
    }

    /// Inverse assuming (near-)unit length.
    public var inverse: Quaternion { conjugate }

    /// Hamilton product.
    public static func * (l: Quaternion, r: Quaternion) -> Quaternion {
        let lv = l.imaginary, rv = r.imaginary
        let w = l.w * r.w - lv.dot(rv)
        let v = l.w * rv + r.w * lv + lv.cross(rv)
        return Quaternion(vector: SIMD4(v.x, v.y, v.z, w))
    }

    /// Rotates a vector: q v q⁻¹, expanded to the standard two-cross form.
    public func act(_ v: Position) -> Position {
        let qv = imaginary
        let t = 2 * qv.cross(v)
        return v + w * t + qv.cross(t)
    }

    /// Spherical interpolation with nlerp fallback for nearly-parallel inputs.
    public static func slerp(_ a: Quaternion, _ b: Quaternion, _ t: Real) -> Quaternion {
        var cosTheta = (a.vector * b.vector).sum()
        var bv = b.vector
        if cosTheta < 0 {  // take the short arc
            cosTheta = -cosTheta
            bv = -bv
        }
        if cosTheta > 0.9995 {
            return Quaternion(vector: a.vector + (bv - a.vector) * t).normalized
        }
        let theta = Real.acos(min(max(cosTheta, -1), 1))
        let sinTheta = Real.sin(theta)
        let wa = Real.sin((1 - t) * theta) / sinTheta
        let wb = Real.sin(t * theta) / sinTheta
        return Quaternion(vector: a.vector * wa + bv * wb).normalized
    }

    /// Column-major rotation matrix.
    public var matrix: Matrix4 {
        let x = vector.x, y = vector.y, z = vector.z, w = vector.w
        let xx = x * x, yy = y * y, zz = z * z
        let xy = x * y, xz = x * z, yz = y * z
        let wx = w * x, wy = w * y, wz = w * z
        return Matrix4(
            SIMD4(1 - 2 * (yy + zz), 2 * (xy + wz), 2 * (xz - wy), 0),
            SIMD4(2 * (xy - wz), 1 - 2 * (xx + zz), 2 * (yz + wx), 0),
            SIMD4(2 * (xz + wy), 2 * (yz - wx), 1 - 2 * (xx + yy), 0),
            SIMD4(0, 0, 0, 1)
        )
    }

    public var debugDescription: String {
        "q(\(fmt(vector.x)), \(fmt(vector.y)), \(fmt(vector.z)), \(fmt(vector.w)))"
    }
}
