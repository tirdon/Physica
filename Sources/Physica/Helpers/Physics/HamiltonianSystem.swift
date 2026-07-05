// HamiltonianSystem — symplectic rigid-body integration in momentum form plus
// SDF-sampled contacts with impulse response.
//
// Per fixed step: p += F·dt; x += (p/m)·dt; ω = R I⁻¹ Rᵀ L; q += ½ ω̂ q·dt.
// Collisions edit p and L directly (the Hamiltonian state), never velocities.

import PhysicaFoundation
import PhysicaKernel

@MainActor
public final class HamiltonianSystem: System {
    public static var gravity = Position(0, -9.81, 0)
    public static let fixedStep: TimeInterval = 1.0 / 240

    private var accumulator: TimeInterval = 0

    public init(scene: Scene) {}

    public func update(context: SceneUpdateContext) {
        accumulator += Swift.min(context.deltaTime, 1.0 / 30)
        while accumulator >= Self.fixedStep {
            step(Self.fixedStep, in: context.scene)
            accumulator -= Self.fixedStep
        }
    }

    /// One deterministic fixed step — the unit tests drive this directly.
    public func step(_ dt: TimeInterval, in scene: Scene) {
        let all = scene.performQuery(
            .has(PhysicsBodyComponent.self, PhysicsMotionComponent.self)
        )
        guard !all.isEmpty else { return }

        // Bodies that left 3× the visible frame freeze: no integration, no
        // contacts. A body that fell off the floor would otherwise be stepped
        // forever while diverging out of sight.
        let frame = scene.frameBounds
        let cullHalfWidth = frame.size.x * 1.5
        let cullHalfHeight = frame.size.y * 1.5
        let entities = all.filter { entity in
            let offset = entity.position - frame.center
            return Swift.abs(offset.x) <= cullHalfWidth
                && Swift.abs(offset.y) <= cullHalfHeight
        }
        guard !entities.isEmpty else { return }

        // 1. Free symplectic motion.
        for entity in entities {
            guard let body = entity.components[PhysicsBodyComponent.self],
                  body.mode == .dynamic,
                  var motion = entity.components[PhysicsMotionComponent.self] else { continue }

            motion.linearMomentum += Self.gravity * body.mass * dt
            entity.position += motion.linearMomentum / body.mass * dt

            let omega = Self.angularVelocity(body: body, motion: motion, orientation: entity.orientation)
            if omega.lengthSquared > 1e-12 {
                let q = entity.orientation
                let spin = Quaternion(vector: SIMD4(omega.x, omega.y, omega.z, 0)) * q
                entity.orientation = Quaternion(
                    vector: q.vector + spin.vector * (dt / 2)
                ).normalized
            }

            entity.components[PhysicsMotionComponent.self] = motion
        }

        // 2. Contacts (pairwise, AABB-culled).
        for indexA in 0..<entities.count {
            for indexB in (indexA + 1)..<entities.count {
                resolvePair(entities[indexA], entities[indexB])
            }
        }
    }

    static func angularVelocity(
        body: PhysicsBodyComponent, motion: PhysicsMotionComponent, orientation: Quaternion
    ) -> Position {
        let inertia = body.shape.inertiaDiagonal(mass: body.mass)
        let bodyL = orientation.inverse.rotate(motion.angularMomentum)
        let bodyOmega = Position(
            inertia.x > 0 ? bodyL.x / inertia.x : 0,
            inertia.y > 0 ? bodyL.y / inertia.y : 0,
            inertia.z > 0 ? bodyL.z / inertia.z : 0
        )
        return orientation.rotate(bodyOmega)
    }

    // MARK: Contacts

    private struct Contact {
        var point: Position      // world
        var normal: Position     // world, from A toward B
        var penetration: Real    // > 0 when overlapping
    }

    private func resolvePair(_ entityA: Entity, _ entityB: Entity) {
        guard let bodyA = entityA.components[PhysicsBodyComponent.self],
              let bodyB = entityB.components[PhysicsBodyComponent.self] else { return }
        if bodyA.mode == .static, bodyB.mode == .static { return }

        // Broadphase: bounding spheres.
        let centerDistance = entityA.position.distance(to: entityB.position)
        if centerDistance > bodyA.shape.boundingRadius + bodyB.shape.boundingRadius + 0.01 {
            return
        }

        guard let contact = Self.deepestContact(
            entityA: entityA, bodyA: bodyA, entityB: entityB, bodyB: bodyB
        ) else { return }

        applyImpulse(contact, entityA: entityA, bodyA: bodyA, entityB: entityB, bodyB: bodyB)
    }

    /// Samples B's surface points against A's SDF and vice versa; keeps the deepest.
    private static func deepestContact(
        entityA: Entity, bodyA: PhysicsBodyComponent,
        entityB: Entity, bodyB: PhysicsBodyComponent
    ) -> Contact? {
        var best: Contact?

        func scan(
            sampleEntity: Entity, sampleBody: PhysicsBodyComponent,
            fieldEntity: Entity, fieldBody: PhysicsBodyComponent,
            flipNormal: Bool
        ) {
            let sampleTransform = sampleEntity.transform
            let fieldTransform = fieldEntity.transform
            let fieldInverse = fieldTransform.orientation.inverse

            for sample in sampleBody.samples {
                let world = sampleTransform.applying(to: sample)
                let local = fieldInverse.rotate(world - fieldTransform.position)
                let distance = fieldBody.shape.distance(at: local)
                guard distance < 0 else { continue }
                let penetration = -distance
                if penetration > (best?.penetration ?? 0) {
                    // Outward gradient of the field body, in world space.
                    var normal = fieldTransform.orientation.rotate(fieldBody.shape.gradient(at: local))
                    if !flipNormal { normal = -normal }  // orient A → B
                    best = Contact(point: world, normal: normal, penetration: penetration)
                }
            }
        }

        // B's points inside A's field: gradient points from A's surface outward (A → B).
        scan(sampleEntity: entityB, sampleBody: bodyB, fieldEntity: entityA, fieldBody: bodyA, flipNormal: true)
        // A's points inside B's field: gradient points B → A, so flip.
        scan(sampleEntity: entityA, sampleBody: bodyA, fieldEntity: entityB, fieldBody: bodyB, flipNormal: false)
        return best
    }

    private func applyImpulse(
        _ contact: Contact,
        entityA: Entity, bodyA: PhysicsBodyComponent,
        entityB: Entity, bodyB: PhysicsBodyComponent
    ) {
        var motionA = entityA.components[PhysicsMotionComponent.self] ?? PhysicsMotionComponent()
        var motionB = entityB.components[PhysicsMotionComponent.self] ?? PhysicsMotionComponent()

        let dynamicA = bodyA.mode == .dynamic
        let dynamicB = bodyB.mode == .dynamic
        let inverseMassA: Real = dynamicA ? 1 / bodyA.mass : 0
        let inverseMassB: Real = dynamicB ? 1 / bodyB.mass : 0

        let armA = contact.point - entityA.position
        let armB = contact.point - entityB.position
        let normal = contact.normal

        func inverseInertiaApply(
            _ vector: Position, body: PhysicsBodyComponent, entity: Entity, isDynamic: Bool
        ) -> Position {
            guard isDynamic else { return .zero }
            let inertia = body.shape.inertiaDiagonal(mass: body.mass)
            let local = entity.orientation.inverse.rotate(vector)
            let scaled = Position(
                inertia.x > 0 ? local.x / inertia.x : 0,
                inertia.y > 0 ? local.y / inertia.y : 0,
                inertia.z > 0 ? local.z / inertia.z : 0
            )
            return entity.orientation.rotate(scaled)
        }

        // Velocities at the contact point.
        let omegaA = Self.angularVelocity(body: bodyA, motion: motionA, orientation: entityA.orientation)
        let omegaB = Self.angularVelocity(body: bodyB, motion: motionB, orientation: entityB.orientation)
        let velocityA = (dynamicA ? motionA.linearMomentum / bodyA.mass : .zero) + omegaA.cross(armA)
        let velocityB = (dynamicB ? motionB.linearMomentum / bodyB.mass : .zero) + omegaB.cross(armB)
        let relative = velocityB - velocityA
        let approaching = relative.dot(normal)

        if approaching < 0 {
            let restitution = Swift.min(bodyA.restitution, bodyB.restitution)
            let angularTermA = inverseInertiaApply(armA.cross(normal), body: bodyA, entity: entityA, isDynamic: dynamicA)
                .cross(armA)
            let angularTermB = inverseInertiaApply(armB.cross(normal), body: bodyB, entity: entityB, isDynamic: dynamicB)
                .cross(armB)
            let denominator = inverseMassA + inverseMassB + (angularTermA + angularTermB).dot(normal)
            guard denominator > 1e-9 else { return }

            let magnitude = -(1 + restitution) * approaching / denominator
            let impulse = normal * magnitude

            if dynamicA {
                motionA.linearMomentum -= impulse
                motionA.angularMomentum -= armA.cross(impulse)
            }
            if dynamicB {
                motionB.linearMomentum += impulse
                motionB.angularMomentum += armB.cross(impulse)
            }

            // Coulomb-clamped friction along the tangent.
            let tangentVelocity = relative - normal * approaching
            let tangentSpeed = tangentVelocity.length
            if tangentSpeed > 1e-6 {
                let tangent = tangentVelocity / tangentSpeed
                let friction = Swift.max(bodyA.friction, bodyB.friction)
                let frictionMagnitude = Swift.min(
                    friction * magnitude,
                    tangentSpeed / Swift.max(inverseMassA + inverseMassB, 1e-9)
                )
                let frictionImpulse = tangent * frictionMagnitude
                if dynamicA {
                    motionA.linearMomentum += frictionImpulse
                    motionA.angularMomentum += armA.cross(frictionImpulse)
                }
                if dynamicB {
                    motionB.linearMomentum -= frictionImpulse
                    motionB.angularMomentum -= armB.cross(frictionImpulse)
                }
            }
        }

        // Positional correction: push out 80% of the penetration.
        let totalInverseMass = inverseMassA + inverseMassB
        if totalInverseMass > 0 {
            let correction = normal * (contact.penetration * 0.8 / totalInverseMass)
            if dynamicA { entityA.position -= correction * inverseMassA }
            if dynamicB { entityB.position += correction * inverseMassB }
        }

        entityA.components[PhysicsMotionComponent.self] = motionA
        entityB.components[PhysicsMotionComponent.self] = motionB
    }
}

// MARK: - Convenience

@MainActor
public extension MeshEntity {
    /// A MeshEntity whose display mesh matches its collision shape.
    static func body(
        _ shape: PhysicsShape,
        mass: Real = 1,
        restitution: Real = 0.4,
        color: Color = .blue,
        mode: PhysicsBodyComponent.Mode = .dynamic
    ) -> MeshEntity {
        let entity = MeshEntity(mesh: shape.mesh(), color: color)
        entity.components[PhysicsBodyComponent.self] = PhysicsBodyComponent(
            shape: shape, mass: mass, restitution: restitution, mode: mode
        )
        entity.components[PhysicsMotionComponent.self] = PhysicsMotionComponent()
        return entity
    }
}
