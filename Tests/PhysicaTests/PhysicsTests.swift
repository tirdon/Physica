import Testing
@testable import Physica

@Suite @MainActor
struct PhysicsTests {
    private func makeWorld() -> (Scene, HamiltonianSystem) {
        let scene = Scene()
        let system = HamiltonianSystem(scene: scene)
        return (scene, system)
    }

    private func hammer(_ system: HamiltonianSystem, _ scene: Scene, steps: Int) {
        for _ in 0..<steps {
            system.step(HamiltonianSystem.fixedStep, in: scene)
        }
    }

    @Test func freeFallMatchesClosedForm() {
        let (scene, system) = makeWorld()
        let ball = MeshEntity.body(.sphere(radius: 0.5), mass: 2)
        ball.position = Position(0, 10, 0)
        scene.insert(ball)

        let dt = HamiltonianSystem.fixedStep
        let steps = 600  // 2.5 s
        hammer(system, scene, steps: steps)

        let time = TimeInterval(steps) * dt
        let gravity = HamiltonianSystem.gravity.y
        // Symplectic Euler: y = y0 + g·dt²·n(n+1)/2 (≈ ½gt² with O(dt) bias).
        let expected = 10 + gravity * dt * dt * Real(steps) * Real(steps + 1) / 2
        #expect(approx(ball.position.y, expected, tolerance: 1e-3))

        // Momentum is exact: p = m·g·t.
        let momentum = ball.components[PhysicsMotionComponent.self]!.linearMomentum
        #expect(approx(momentum.y, 2 * gravity * time, tolerance: 1e-6))
        #expect(approx(momentum.x, 0))
    }

    @Test func equalSphereHeadOnElasticSwap() {
        let (scene, system) = makeWorld()
        let left = MeshEntity.body(.sphere(radius: 0.5), mass: 1, restitution: 1)
        let right = MeshEntity.body(.sphere(radius: 0.5), mass: 1, restitution: 1)
        left.position = Position(-1.2, 0, 0)
        right.position = Position(1.2, 0, 0)
        left.components[PhysicsMotionComponent.self] = PhysicsMotionComponent(
            linearMomentum: Position(3, 0, 0)
        )
        scene.insert(left)
        scene.insert(right)
        let savedGravity = HamiltonianSystem.gravity
        HamiltonianSystem.gravity = .zero
        defer { HamiltonianSystem.gravity = savedGravity }

        hammer(system, scene, steps: 400)

        let pLeft = left.components[PhysicsMotionComponent.self]!.linearMomentum
        let pRight = right.components[PhysicsMotionComponent.self]!.linearMomentum
        // Elastic head-on equal masses: momentum transfers completely.
        #expect(approx(pLeft.x, 0, tolerance: 0.05))
        #expect(approx(pRight.x, 3, tolerance: 0.05))
        // Total momentum conserved exactly.
        #expect(approx(pLeft.x + pRight.x, 3, tolerance: 1e-6))
    }

    @Test func restitutionControlsBounce() {
        let (scene, system) = makeWorld()
        let floor = MeshEntity.body(
            .box(halfExtents: SIMD3(10, 0.5, 10)), restitution: 1, mode: .static
        )
        floor.position = Position(0, -0.5, 0)
        let ball = MeshEntity.body(.sphere(radius: 0.5), mass: 1, restitution: 0.5)
        ball.position = Position(0, 3, 0)
        scene.insert(floor)
        scene.insert(ball)

        // Track impact and rebound speeds around the first bounce.
        var impactSpeed: Real = 0
        var reboundSpeed: Real = 0
        for _ in 0..<2000 {
            let before = ball.components[PhysicsMotionComponent.self]!.linearMomentum.y
            system.step(HamiltonianSystem.fixedStep, in: scene)
            let after = ball.components[PhysicsMotionComponent.self]!.linearMomentum.y
            if before < 0, after > 0 {
                impactSpeed = -before
                reboundSpeed = after
                break
            }
        }
        #expect(impactSpeed > 5)
        #expect(approx(reboundSpeed / impactSpeed, 0.5, tolerance: 0.06))
    }

    @Test func sphereSettlesOnFloor() {
        let (scene, system) = makeWorld()
        let floor = MeshEntity.body(
            .box(halfExtents: SIMD3(10, 0.5, 10)), restitution: 0.1, mode: .static
        )
        floor.position = Position(0, -0.5, 0)
        let ball = MeshEntity.body(.sphere(radius: 0.5), mass: 1, restitution: 0.1)
        ball.position = Position(0, 2, 0)
        scene.insert(floor)
        scene.insert(ball)

        hammer(system, scene, steps: 1500)  // ~6 s

        #expect(approx(ball.position.y, 0.5, tolerance: 0.08))
        let momentum = ball.components[PhysicsMotionComponent.self]!.linearMomentum
        #expect(Swift.abs(momentum.y) < 0.6)
        #expect(approx(ball.position.x, 0, tolerance: 0.05))
    }

    @Test func inertiaFormulas() {
        let sphere = PhysicsShape.sphere(radius: 2).inertiaDiagonal(mass: 5)
        #expect(approx(sphere.x, 0.4 * 5 * 4))

        let box = PhysicsShape.box(halfExtents: SIMD3(1, 2, 3)).inertiaDiagonal(mass: 3)
        #expect(approx(box.x, 1 * (4 + 9)))     // m/3 (hy²+hz²)
        #expect(approx(box.y, 1 * (1 + 9)))
        #expect(approx(box.z, 1 * (1 + 4)))

        let torus = PhysicsShape.torus(majorRadius: 2, minorRadius: 0.5).inertiaDiagonal(mass: 4)
        #expect(approx(torus.y, 4 * (0.75 * 0.25 + 4)))           // axial (y)
        #expect(approx(torus.x, 4 * (0.625 * 0.25 + 0.5 * 4)))    // diametral
    }

    @Test func sdfSignsAndGradients() {
        let box = PhysicsShape.box(halfExtents: SIMD3(1, 1, 1))
        #expect(box.distance(at: Position(2, 0, 0)) > 0)
        #expect(box.distance(at: Position(0.5, 0, 0)) < 0)
        #expect(approx(box.distance(at: Position(1, 0, 0)), 0, tolerance: 1e-4))
        #expect(approx(box.gradient(at: Position(1.5, 0, 0)), Position(1, 0, 0), tolerance: 1e-2))

        let torus = PhysicsShape.torus(majorRadius: 2, minorRadius: 0.5)
        #expect(approx(torus.distance(at: Position(2.5, 0, 0)), 0, tolerance: 1e-4))
        #expect(torus.distance(at: .origin) > 0)  // hole is outside the solid
        #expect(torus.distance(at: Position(2, 0.2, 0)) < 0)

        let ellipsoid = PhysicsShape.ellipsoid(radii: SIMD3(2, 1, 1))
        #expect(approx(ellipsoid.distance(at: Position(2, 0, 0)), 0, tolerance: 1e-2))
        #expect(ellipsoid.distance(at: Position(0, 0.5, 0)) < 0)
    }

    @Test func torusRestsOnFloorViaSDFContacts() {
        let (scene, system) = makeWorld()
        let floor = MeshEntity.body(
            .box(halfExtents: SIMD3(10, 0.5, 10)), restitution: 0.05, mode: .static
        )
        floor.position = Position(0, -0.5, 0)
        let donut = MeshEntity.body(
            .torus(majorRadius: 0.8, minorRadius: 0.25), mass: 1, restitution: 0.05
        )
        donut.position = Position(0, 1.5, 0)  // lying flat, falls onto the floor
        scene.insert(floor)
        scene.insert(donut)

        hammer(system, scene, steps: 1200)

        // Resting height = minor radius (ring touching the plane).
        #expect(approx(donut.position.y, 0.25, tolerance: 0.1))
    }

    @Test func momentumDebugString() {
        let motion = PhysicsMotionComponent(linearMomentum: Position(1, 0, 0))
        #expect(motion.debugString == "motion(p: (1.000, 0.000, 0.000), L: (0.000, 0.000, 0.000))")
    }
}
