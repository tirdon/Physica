// Values that animation tracks can blend.

public protocol Interpolatable {
    static func lerp(_ from: Self, _ to: Self, _ t: Real) -> Self
}

extension Real: Interpolatable {
    public static func lerp(_ from: Real, _ to: Real, _ t: Real) -> Real {
        from + (to - from) * t
    }
}

extension SIMD2<Real>: Interpolatable {
    public static func lerp(_ from: Self, _ to: Self, _ t: Real) -> Self {
        from + (to - from) * t
    }
}

extension SIMD3<Real>: Interpolatable {}

extension SIMD4<Real>: Interpolatable {
    public static func lerp(_ from: Self, _ to: Self, _ t: Real) -> Self {
        from + (to - from) * t
    }
}

extension Quaternion: Interpolatable {
    public static func lerp(_ from: Quaternion, _ to: Quaternion, _ t: Real) -> Quaternion {
        slerp(from, to, t)
    }
}

extension Color: Interpolatable {}
