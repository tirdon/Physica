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
    static func build(_ scene: Scene, font: Font?, formula: TextEntity? = nil) {
        scene.background = .blackboard
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

        // ---- Custom system takes over; its equation of motion writes itself
        //      overhead while the pendulum swings (MathJax → SVG → glyph paths) ----
        string.components[PendulumComponent.self] = PendulumComponent(.string, string)
        bob.components[PendulumComponent.self] = PendulumComponent(.bob, bob.animationTargets[0])
        if let formula {
            formula.textured(.pencil)
            formula.position = Position(0, 2.35, 0)
            scene.play(.write(formula), for: 2.5.s)
            // Highlight the nonlinearity — "sin θ" is the last four glyphs.
            scene.play(formula[(formula.glyphCount - 4)...].color(.teal), for: 0.5.s)
        }
        scene.wait(3.s)                                        // swing freely
        scene.pause(PendulumSystem.self)                       // frozen for 1 s, then resumes
        scene.wait(1.5.s)

        // ---- Everything to the bottom edge while the pendulum keeps updating.
        //      Group move: one shared delta, so the string keeps its length
        //      (separate .move(to:) calls would pin each entity to the edge). ----
        let pendulum = Group(pivot, string, bob)
        scene.play(pendulum.move(to: .bottom))
        scene.wait(1.5.s)

        // ---- Contrast: separate moves pin EACH entity to its own corner.
        //      Save the arrangement first, then restore the capture. ----
        scene.play(pendulum.saveState())
        scene.play(
            pivot.move(to: .topLeft),
            string.move(to: .bottomLeft),
            bob.move(to: .bottomRight)
        )
        scene.wait(0.8.s)
        scene.play(pendulum.restoreState())
        scene.wait(0.7.s)

        // ---- Hand off: pendulum fades while its equation unwrites ----
        if let formula {
            scene.play(
                .erase(formula),
                pivot.fade(to: 0), string.fade(to: 0), bob.fade(to: 0),
                for: 0.8.s
            )
        } else {
            scene.play(pivot.fade(to: 0), string.fade(to: 0), bob.fade(to: 0), for: 0.6.s)
        }

        // ---- Text write (no scene.add — .write introduces the entity) ----
        var title: TextEntity?
        if let font {
            let text = TextEntity("Physica", font: font, fontSize: 1.2, color: .white)
                .textured(.chalk)
            text.position = Position(0, 2.3, 0)
            scene.play(.write(text))
            // Per-glyph gradient sweep, chalk grain intact.
            scene.play(text.color(mix: [.blue, .teal, .purple]), for: 0.8.s)
            // Neon chase around the title: one lap, tail catches the head.
            scene.play(.highlight(text), for: 1.4.s)
            scene.wait(0.5.s)
            title = text
        }

        // ---- Path morph chain (.draw introduces the entity too) ----
        let shape = Circle(radius: 0.9, color: .blue).stroke(.white, width: 0.035)
        shape.position = Position(-3.6, 0.2, 0)
        scene.play(.draw(shape), for: 1.2.s)
        scene.play(shape.morph(to: Rectangle(width: 1.7, height: 1.7)), shape.color(.teal))
        scene.play(shape.morph(to: Triangle(side: 2)), shape.color(.orange))
        scene.wait(0.5.s)
        // Clear the left flank for the drop: backward draw, then the shape
        // leaves the scene entirely.
        scene.play(.erase(shape), for: 0.8.s)

        // ---- Physics drop: sphere, box, ellipsoid, torus onto a static floor ----
        // Wider than the ±5 frame so bodies rolling out of view stay supported.
        // Deep in z too: the tilted donut rolls along z (depth), and must stay
        // on the slab for the rest of the timeline.
        let floor = MeshEntity.body(
            .box(halfExtents: SIMD3(5.4, 0.18, 7)),
            restitution: 0.5, color: Color(hex: 0x2A2A36), mode: .static
        )
        floor.position = Position(0.2, -2.9, 0)

        let ball = MeshEntity.body(.sphere(radius: 0.45), mass: 1, restitution: 0.65, color: .red)
            .shaded(.toon)
        ball.position = Position(-2.4, 2.4, 0)

        let crate = MeshEntity.body(
            .box(halfExtents: SIMD3(0.4, 0.4, 0.4)), mass: 1.4, restitution: 0.3, color: .green
        )
        crate.position = Position(-0.6, 2.7, 0)
        crate.orientation = Quaternion(angle: 0.5, axis: Position(0.3, 0, 1).normalized)

        let egg = MeshEntity.body(
            .ellipsoid(radii: SIMD3(0.55, 0.38, 0.38)), mass: 1, restitution: 0.5, color: .yellow
        )
        egg.position = Position(1.2, 2.5, 0)
        egg.orientation = Quaternion(angle: 0.4, axis: 1.k)

        let donut = MeshEntity.body(
            .torus(majorRadius: 0.5, minorRadius: 0.18), mass: 0.8, restitution: 0.45, color: .purple
        ).shaded(.toon)
        // Left of the ball: the egg rolls right (its z-tilt makes it lopsided),
        // so the right flank is its runway — nothing may park there.
        donut.position = Position(-3.5, 2.9, 0)
        // Nearly flat: a tilted torus rolls in a curve and escapes the frame;
        // this one bounces, wobbles, and settles where it landed.
        donut.orientation = Quaternion(angle: 0.18, axis: 1.i)

        scene.add(floor, ball, crate, egg, donut)
        scene.wait(5.s)

        // ---- Bookend: unwrite the title ----
        if let title {
            scene.play(.erase(title))
        }
    }
}
#endif
