// Signed-distance functions for the four body shapes (body frame), used for
// uniform contact generation: sample one body's surface against the other's SDF.

import PhysicaFoundation
import PhysicaKernel

public protocol SignedDistanceField: Sendable {
    /// Signed distance from `point` (body frame) to the surface (< 0 inside).
    func distance(at point: Position) -> Real
    /// Outward surface direction at `point`.
    func gradient(at point: Position) -> Position
}

extension PhysicsShape: SignedDistanceField {
    public func distance(at point: Position) -> Real {
        switch self {
        case .sphere(let radius):
            return point.length - radius

        case .box(let half):
            let q = Position(
                Swift.abs(point.x) - half.x,
                Swift.abs(point.y) - half.y,
                Swift.abs(point.z) - half.z
            )
            let outside = Position(
                Swift.max(q.x, 0), Swift.max(q.y, 0), Swift.max(q.z, 0)
            ).length
            let inside = Swift.min(Swift.max(q.x, Swift.max(q.y, q.z)), 0)
            return outside + inside

        case .ellipsoid(let radii):
            // iq's bound-preserving approximation.
            let k0 = (point / radii).length
            let k1 = (point / (radii * radii)).length
            guard k1 > 1e-9 else { return -Swift.min(radii.x, Swift.min(radii.y, radii.z)) }
            return k0 * (k0 - 1) / k1

        case .torus(let major, let minor):
            let ringDistance = (point.x * point.x + point.z * point.z).squareRoot() - major
            return (ringDistance * ringDistance + point.y * point.y).squareRoot() - minor
        }
    }

    public func gradient(at point: Position) -> Position {
        // Central differences — uniform and robust across all shapes.
        let epsilon: Real = 1e-4
        let dx = distance(at: point + Position(epsilon, 0, 0))
            - distance(at: point - Position(epsilon, 0, 0))
        let dy = distance(at: point + Position(0, epsilon, 0))
            - distance(at: point - Position(0, epsilon, 0))
        let dz = distance(at: point + Position(0, 0, epsilon))
            - distance(at: point - Position(0, 0, epsilon))
        let gradient = Position(dx, dy, dz)
        let length = gradient.length
        return length > 1e-9 ? gradient / length : Position(0, 1, 0)
    }
}
