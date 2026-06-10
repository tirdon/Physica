import Testing
@testable import Physica

// The spec's pendulum script, assembled headless with a stub system.

struct PendulumComponent: Component {
    enum Role: Sendable { case string, bob }
    let role: Role
}

@MainActor
private struct PendulumSystemStub: System {
    init(scene: Scene) {}
    func update(context: SceneUpdateContext) {}
}

@Suite @MainActor
struct SceneScriptTests {
    @MainActor
    struct Script {
        let scene = Scene()
        let pivot: Wall
        let string: Line
        let bob: Animation
        let bobCircle: Entity

        init() {
            scene.registerSystem(PendulumSystemStub.self)

            // default animation
            let pivot = Wall(face: .down)                       // = ceiling
            let center = pivot.center
            let string = Line(start: center, end: center - 4.j)
            let bob = Circle().move(to: string.end)
            string.updater = { $0.end = bob.position }
            scene.add(pivot, string, bob)
            scene.play(bob.move(to: 1.i + 1.j), for: 2.s)
            scene.play(bob.move(to: .origin))
            scene.wait()

            self.pivot = pivot
            self.string = string
            self.bob = bob
            self.bobCircle = bob.animationTargets[0]
        }
    }

    @Test func scheduleMatchesSpec() {
        let script = Script()
        let timeline = script.scene.timeline

        // add (0s) + play 2s + play 1s + wait 1s
        #expect(timeline.clips.count == 4)
        #expect(approx(timeline.duration, 4))
        #expect(approx(timeline.clips[0].duration, 0))
        #expect(approx(timeline.clips[1].duration, 2))
        #expect(approx(timeline.clips[2].duration, 1))
        #expect(approx(timeline.clips[3].duration, 1))

        // Nothing exists until the first frame plays the add clip.
        #expect(script.scene.entities.isEmpty)
    }

    @Test func setupStateAfterFirstFrame() {
        let script = Script()
        script.scene.update(deltaTime: 0.001)

        #expect(script.scene.entities.count == 3)
        #expect(approx(script.pivot.center, Position(0, 3.8, 0)))
        // bob carried `move(to: string.end)` into the add clip
        #expect(approx(script.bobCircle.position, Position(0, -0.2, 0), tolerance: 1e-2))
        // updater synced the string to the bob on the same frame
        #expect(approx(script.string.end, script.bobCircle.position, tolerance: 1e-3))
    }

    @Test func playbackAndStringFollowsBob() {
        let script = Script()

        // Through the first play (t = 2): bob at (1, 1, 0)
        script.scene.update(deltaTime: 2.0)
        #expect(approx(script.bobCircle.position, Position(1, 1, 0), tolerance: 1e-3))
        #expect(approx(script.string.end, Position(1, 1, 0), tolerance: 1e-3))
        #expect(approx(script.string.start, Position(0, 3.8, 0)))

        // Through the second play (t = 3): bob back at origin
        script.scene.update(deltaTime: 1.0)
        #expect(approx(script.bobCircle.position, .origin, tolerance: 1e-3))

        // Wait clip runs out; timeline finished
        script.scene.update(deltaTime: 1.0)
        #expect(script.scene.timeline.isFinished)
    }

    @Test func seekMidFlightInterpolatesAndSyncsDerivedState() {
        let script = Script()
        script.scene.update(deltaTime: 4.5)  // play everything
        script.scene.seek(to: 1.0)           // halfway through the 2s move

        let expected = Position.lerp(
            Position(0, -0.2, 0), Position(1, 1, 0), Easing.smooth.apply(0.5)
        )
        #expect(approx(script.bobCircle.position, expected, tolerance: 1e-2))
        #expect(approx(script.string.end, script.bobCircle.position, tolerance: 1e-3))
        #expect(script.scene.timeline.isPaused)

        // Scrub to 0: entities present (add clip is at t = 0), bob at its start.
        script.scene.seek(to: 0)
        #expect(script.scene.entities.count == 3)
        #expect(approx(script.bobCircle.position, Position(0, -0.2, 0), tolerance: 1e-2))

        // Resume and replay to the end.
        script.scene.resume()
        script.scene.update(deltaTime: 4.0)
        #expect(script.scene.timeline.isFinished)
        #expect(approx(script.bobCircle.position, .origin, tolerance: 1e-3))
    }

    @Test func pauseSystemClipMatchesSpecShape() {
        let script = Script()
        script.scene.pause(PendulumSystemStub.self)  // 1s suspension clip
        #expect(script.scene.timeline.clips.count == 5)
        #expect(script.scene.timeline.clips[4].label == "pause(PendulumSystemStub)")
        #expect(approx(script.scene.timeline.duration, 5))
    }

    @Test func sceneDebugStringIsStable() {
        let script = Script()
        script.scene.name = "pendulum"
        script.scene.update(deltaTime: 0.001)
        let lines = script.scene.debugString.split(separator: "\n").map(String.init)
        #expect(lines[0] == "Scene 'pendulum' entities(3):")
        #expect(lines[1].hasPrefix("  Wall pos(0.000, 3.800, 0.000)"))
        #expect(lines[2].hasPrefix("  Line pos(0.000, 0.000, 0.000)"))
        #expect(lines[3].hasPrefix("  Circle pos"))
    }
}
