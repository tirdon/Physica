// The spec's pendulum script, verbatim shape, followed by showcase segments
// (text Write, path morphs, physics drop) on the same scrubbable timeline.

#if os(WASI)
import Physica

// MARK: - Pendulum (custom component + system, as in the spec)

struct PendulumComponent: Component {
    enum Role: Sendable {
        case string, bob
    }

    let role: Role
    weak var entity: Entity?
    var angularVelocity: Real = 1.6

    init(_ role: Role, _ entity: Entity) {
        self.role = role
        self.entity = entity
    }
}

@MainActor
struct PendulumSystem: System {
    init(scene: Scene) {}

    func update(context: SceneUpdateContext) {
        let members = context.entities(matching: .has(PendulumComponent.self))
        guard
            let bob = members.first(where: { $0.components[PendulumComponent.self]?.role == .bob }),
            let string = members.first(where: { $0.components[PendulumComponent.self]?.role == .string }) as? Line,
            var pendulum = bob.components[PendulumComponent.self]
        else { return }

        // Pivot = the string's start in world space; re-derive θ from the bob's
        // current position so concurrent animations/scrubs hand over smoothly.
        let pivot = string.worldTransform.applying(to: string.start)
        let delta = bob.position - pivot
        let length = max(delta.length, 0.05)
        var theta = Real.atan2(delta.x, -delta.y)

        let dt = min(context.deltaTime, 1.0 / 30)
        pendulum.angularVelocity -= (9.81 / length) * Real.sin(theta) * dt
        theta += pendulum.angularVelocity * dt
        bob.position = pivot + Position(length * Real.sin(theta), -length * Real.cos(theta), 0)
        bob.components[PendulumComponent.self] = pendulum
    }
}

// MARK: - Demo timeline

@MainActor
enum PendulumDemo {
    static func build(_ scene: Scene, font: Font?) {
        scene.registerSystem(PendulumSystem.self)
        scene.registerSystem(HamiltonianSystem.self)

        // ---- Spec script (default animation) ----
        let pivot = Wall(face: .down)                          // = ceiling
        let center = pivot.center
        let string = Line(start: center, end: center - 4.j)
        let bob = Circle().move(to: string.end)
        string.updater = { [weak bob = bob.animationTargets.first] line in
            guard let bob else { return }
            line.end = line.convert(worldPosition: bob.position)
        }
        scene.add(pivot, string, bob)
        scene.play(bob.move(to: 1.i + 1.j), for: 2.s)
        scene.play(bob.move(to: .origin))
        scene.wait()

        // ---- Custom system takes over ----
        string.components[PendulumComponent.self] = PendulumComponent(.string, string)
        bob.components[PendulumComponent.self] = PendulumComponent(.bob, bob.animationTargets[0])
        scene.wait(3.s)                                        // swing freely
        scene.pause(PendulumSystem.self)                       // frozen for 1 s, then resumes
        scene.wait(1.5.s)

        // ---- Everything to the bottom edge while the pendulum keeps updating ----
        scene.play(pivot.move(to: .bottom), string.move(to: .bottom), bob.move(to: .bottom))
        scene.wait(1.5.s)

        // ---- Hand off: fade the pendulum out ----
        scene.play(pivot.fade(to: 0), string.fade(to: 0), bob.fade(to: 0), for: 0.6.s)

        // ---- Text write ----
        if let font {
            let title = TextEntity("Physica", font: font, fontSize: 1.5, color: .white)
            title.position = Position(0, 2.6, 0)
            scene.add(title)
            scene.play(title.write())
            scene.wait(0.5.s)
        }

        // ---- Path morph chain ----
        let shape = Circle(radius: 0.9, color: .blue).stroke(.white, width: 0.035)
        shape.position = Position(-3.6, 0.2, 0)
        scene.add(shape)
        scene.play(shape.draw(), for: 1.2.s)
        scene.play(shape.morph(to: Rectangle(width: 1.7, height: 1.7)), shape.setColor(to: .teal))
        scene.play(shape.morph(to: Triangle(side: 2)), shape.setColor(to: .orange))
        scene.wait(0.5.s)

        // ---- Physics drop: sphere, box, ellipsoid, torus onto a static floor ----
        let floor = MeshEntity.body(
            .box(halfExtents: SIMD3(5.2, 0.18, 2)),
            restitution: 0.9, color: Color(hex: 0x2A2A36), mode: .static
        )
        floor.position = Position(1.4, -3.2, 0)

        let ball = MeshEntity.body(.sphere(radius: 0.45), mass: 1, restitution: 0.65, color: .red)
        ball.position = Position(-1.4, 2.6, 0)

        let crate = MeshEntity.body(
            .box(halfExtents: SIMD3(0.4, 0.4, 0.4)), mass: 1.4, restitution: 0.3, color: .green
        )
        crate.position = Position(0.4, 3.4, 0)
        crate.orientation = Quaternion(angle: 0.5, axis: Position(0.3, 0, 1).normalized)

        let egg = MeshEntity.body(
            .ellipsoid(radii: SIMD3(0.55, 0.38, 0.38)), mass: 1, restitution: 0.5, color: .yellow
        )
        egg.position = Position(2.2, 2.9, 0)
        egg.orientation = Quaternion(angle: 0.4, axis: 1.k)

        let donut = MeshEntity.body(
            .torus(majorRadius: 0.5, minorRadius: 0.18), mass: 0.8, restitution: 0.45, color: .purple
        )
        donut.position = Position(3.9, 3.6, 0)
        donut.orientation = Quaternion(angle: 0.9, axis: Position(1, 0, 0.2).normalized)
        donut.components[PhysicsMotionComponent.self] = PhysicsMotionComponent(
            angularMomentum: Position(0.05, 0.02, 0)
        )

        scene.add(floor, ball, crate, egg, donut)
        scene.wait(5.s)
    }
}
#endif
