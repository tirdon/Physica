import Testing
@testable import Physica

@Suite @MainActor
struct HighlightTests {
    @Test func neonLoopChasesAndCleansUp() {
        let scene = Scene()
        let subject = Circle(radius: 1)
        subject.position = Position(1, 0.5, 0)
        scene.add(subject)
        scene.wait(1.s)
        scene.play(.highlight(subject), for: 1.s, easing: .linear)

        // Mid-loop: the transient border is in the scene, head leads tail.
        scene.update(deltaTime: 1.5)
        #expect(scene.entities.count == 2)
        guard let border = scene.entities.first(where: { $0 !== subject }) else {
            Issue.record("expected the highlight border entity")
            return
        }
        #expect(border.components[RenderStyleComponent.self]?.neon == true)
        let component = border.components[PathComponent.self]
        // Linear raw 0.5: head = 0.5 / 0.62 of the lap, tail = 0.12 / 0.62.
        #expect(approx(component?.strokeProgress ?? -1, 0.5 / 0.62, tolerance: 1e-3))
        #expect(approx(component?.strokeStart ?? -1, 0.12 / 0.62, tolerance: 1e-3))

        // The border surrounds the subject's bounds + default padding 0.3.
        let bounds = (border as? PathEntity)?.path.bounds ?? .empty
        #expect(approx(bounds.min.x, -0.3, tolerance: 1e-3))
        #expect(approx(bounds.max.x, 2.3, tolerance: 1e-3))
        #expect(approx(bounds.min.y, -0.8, tolerance: 1e-3))
        #expect(approx(bounds.max.y, 1.8, tolerance: 1e-3))

        // When the lap completes the border leaves the scene.
        scene.update(deltaTime: 0.6)
        #expect(scene.entities.count == 1)
        #expect(scene.entities[0] === subject)

        // Scrub back inside the window: the chase resurrects mid-lap…
        scene.seek(to: 1.5)
        #expect(scene.entities.count == 2)

        // …and scrubbing before the clip removes it again.
        scene.seek(to: 0.5)
        #expect(scene.entities.count == 1)
        #expect(scene.entities[0] === subject)
    }

    @Test func highlightDefaultDurationIsOneLap() {
        let scene = Scene()
        let subject = Circle()
        scene.add(subject)
        scene.play(.highlight(subject))
        #expect(approx(scene.timeline.clips[1].duration, 1.2))
    }

    @Test func tailMeetsHeadAtTheEnd() {
        let scene = Scene()
        let subject = Circle()
        scene.add(subject)
        scene.play(.highlight(subject), for: 1.s, easing: .linear)

        scene.seek(to: 0.9999)
        guard let border = scene.entities.first(where: { $0 !== subject }),
              let component = border.components[PathComponent.self] else {
            Issue.record("expected the border just before the clip end")
            return
        }
        // Nothing left to draw: the window has zero width.
        #expect(approx(component.strokeProgress, 1, tolerance: 1e-3))
        #expect(approx(component.strokeStart, 1, tolerance: 1e-3))
    }
}
