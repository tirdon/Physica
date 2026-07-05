// Physics bodies in Hamiltonian form: state is (transform, linear momentum p,
// angular momentum L); velocities are derived (v = p/m, ω = R I⁻¹ Rᵀ L).

import PhysicaMath
import PhysicaGeometry
import PhysicaKernel

public enum PhysicsShape: Sendable, Equatable {
    case sphere(radius: Real)
    case box(halfExtents: SIMD3<Real>)
    case ellipsoid(radii: SIMD3<Real>)
    /// Ring in the xz plane, y is the symmetry axis (matches `Mesh.torus`).
    case torus(majorRadius: Real, minorRadius: Real)

    /// Analytic principal-frame inertia diagonal.
    public func inertiaDiagonal(mass: Real) -> SIMD3<Real> {
        switch self {
        case .sphere(let radius):
            let inertia = 0.4 * mass * radius * radius
            return SIMD3(inertia, inertia, inertia)
        case .box(let half):
            let factor = mass / 3
            return SIMD3(
                factor * (half.y * half.y + half.z * half.z),
                factor * (half.x * half.x + half.z * half.z),
                factor * (half.x * half.x + half.y * half.y)
            )
        case .ellipsoid(let radii):
            let factor = mass / 5
            return SIMD3(
                factor * (radii.y * radii.y + radii.z * radii.z),
                factor * (radii.x * radii.x + radii.z * radii.z),
                factor * (radii.x * radii.x + radii.y * radii.y)
            )
        case .torus(let major, let minor):
            let axial = mass * (0.75 * minor * minor + major * major)
            let diametral = mass * (0.625 * minor * minor + 0.5 * major * major)
            return SIMD3(diametral, axial, diametral)  // y = symmetry axis
        }
    }

    public var boundingRadius: Real {
        switch self {
        case .sphere(let radius):
            return radius
        case .box(let half):
            return half.length
        case .ellipsoid(let radii):
            return Swift.max(radii.x, Swift.max(radii.y, radii.z))
        case .torus(let major, let minor):
            return major + minor
        }
    }

    /// Display mesh matching the collision shape.
    public func mesh() -> Mesh {
        switch self {
        case .sphere(let radius):
            return .sphere(radius: radius)
        case .box(let half):
            return .box(size: half * 2)
        case .ellipsoid(let radii):
            return .ellipsoid(radii: radii)
        case .torus(let major, let minor):
            return .torus(majorRadius: major, minorRadius: minor)
        }
    }

    /// Surface points (body frame) used for SDF contact sampling.
    public func surfaceSamples(target: Int = 96) -> [Position] {
        let vertices = mesh().positions
        guard vertices.count > target else { return vertices }
        let stride = Swift.max(vertices.count / target, 1)
        var samples: [Position] = []
        samples.reserveCapacity(target + 1)
        var index = 0
        while index < vertices.count {
            samples.append(vertices[index])
            index += stride
        }
        return samples
    }
}

public struct PhysicsBodyComponent: Component {
    public enum Mode: Sendable, Equatable {
        case dynamic
        case `static`
    }

    public var shape: PhysicsShape
    public var mass: Real
    public var restitution: Real
    public var friction: Real
    public var mode: Mode
    /// Precomputed contact sample set (body frame).
    public let samples: [Position]

    public init(
        shape: PhysicsShape,
        mass: Real = 1,
        restitution: Real = 0.4,
        friction: Real = 0.3,
        mode: Mode = .dynamic
    ) {
        self.shape = shape
        self.mass = mass
        self.restitution = restitution
        self.friction = friction
        self.mode = mode
        self.samples = shape.surfaceSamples()
    }

    public var debugString: String {
        "body(\(shape), m: \(fmt(mass, decimals: 2)), \(mode == .dynamic ? "dynamic" : "static"))"
    }
}

public struct PhysicsMotionComponent: Component {
    /// p = m·v (world frame).
    public var linearMomentum: SIMD3<Real>
    /// L (world frame).
    public var angularMomentum: SIMD3<Real>

    public init(
        linearMomentum: SIMD3<Real> = .zero,
        angularMomentum: SIMD3<Real> = .zero
    ) {
        self.linearMomentum = linearMomentum
        self.angularMomentum = angularMomentum
    }

    public var debugString: String {
        "motion(p: \(fmt(linearMomentum)), L: \(fmt(angularMomentum)))"
    }
}
