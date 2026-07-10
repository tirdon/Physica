import Testing
@testable import PhysicaFoundation
@testable import PhysicaAlgebra
@testable import PhysicaTypesetting
@testable import PhysicaKernel
@testable import PhysicaCharts
@testable import PhysicaPhysics
@testable import PhysicaEquationGame

@Suite @MainActor
struct HighlightTests {
    @Test func borderDrawsHoldsThenFadesAndCleansUp() {
        let scene = Scene()
        let subject = Circle(radius: 1)
        subject.position = Position(1, 0.5, 0)
        scene.add(subject)
        scene.wait(1.s)
        scene.play(.highlight(subject), for: 1.s, easing: .linear)

        // Draw phase (raw 0.2): the transient border is in the scene, the
        // stroke head is partway around, the tail never moves, fully opaque.
        scene.update(deltaTime: 1.2)
        #expect(scene.entities.count == 2)
        guard let border = scene.entities.first(where: { $0 !== subject }) else {
            Issue.record("expected the highlight border entity")
            return
        }
        #expect(border.components[RenderStyleComponent.self]?.neon == true)
        let component = border.components[PathComponent.self]
        // Linear raw 0.2: head = 0.2 / 0.35 of the loop, still fully lit.
        #expect(approx(component?.strokeProgress ?? -1, 0.2 / 0.35, tolerance: 1e-3))
        #expect(approx(component?.strokeStart ?? -1, 0, tolerance: 1e-3))
        #expect(approx(border.components[RenderStyleComponent.self]?.opacity ?? -1, 1, tolerance: 1e-3))

        // The border surrounds the subject's bounds + default padding 0.3.
        let bounds = (border as? PathEntity)?.path.bounds ?? .empty
        #expect(approx(bounds.min.x, -0.3, tolerance: 1e-3))
        #expect(approx(bounds.max.x, 2.3, tolerance: 1e-3))
        #expect(approx(bounds.min.y, -0.8, tolerance: 1e-3))
        #expect(approx(bounds.max.y, 1.8, tolerance: 1e-3))

        // Hold phase (raw 0.5): fully drawn, still fully opaque.
        scene.update(deltaTime: 0.3)
        #expect(approx(border.components[PathComponent.self]?.strokeProgress ?? -1, 1, tolerance: 1e-3))
        #expect(approx(border.components[RenderStyleComponent.self]?.opacity ?? -1, 1, tolerance: 1e-3))

        // Fade phase (raw 0.85): the whole loop dims, halfway gone.
        scene.update(deltaTime: 0.35)
        #expect(approx(border.components[PathComponent.self]?.strokeProgress ?? -1, 1, tolerance: 1e-3))
        #expect(approx(border.components[RenderStyleComponent.self]?.opacity ?? -1, 0.5, tolerance: 1e-3))

        // When the fade completes the border leaves the scene.
        scene.update(deltaTime: 0.2)
        #expect(scene.entities.count == 1)
        #expect(scene.entities[0] === subject)

        // Scrub back inside the window: the border resurrects mid-hold…
        scene.seek(to: 1.5)
        #expect(scene.entities.count == 2)
        #expect(approx(border.components[RenderStyleComponent.self]?.opacity ?? -1, 1, tolerance: 1e-3))

        // …and scrubbing before the clip removes it again.
        scene.seek(to: 0.5)
        #expect(scene.entities.count == 1)
        #expect(scene.entities[0] === subject)
    }

    @Test func highlightDefaultDuration() {
        let scene = Scene()
        let subject = Circle()
        scene.add(subject)
        scene.play(.highlight(subject))
        #expect(approx(scene.timeline.clips[1].duration, 1.2))
    }

    @Test func chaseStyleHeadLapsWhileTailFollows() {
        let scene = Scene()
        let subject = Circle(radius: 1)
        subject.position = Position(1, 0.5, 0)
        scene.add(subject)
        scene.play(.highlight(subject, style: .chase), for: 1.s, easing: .linear)

        // Mid-loop: head leads tail, opacity untouched (the chase never fades).
        scene.seek(to: 0.5)
        guard let border = scene.entities.first(where: { $0 !== subject }) else {
            Issue.record("expected the highlight border entity")
            return
        }
        let component = border.components[PathComponent.self]
        // Linear raw 0.5: head = 0.5 / 0.62 of the lap, tail = 0.12 / 0.62.
        #expect(approx(component?.strokeProgress ?? -1, 0.5 / 0.62, tolerance: 1e-3))
        #expect(approx(component?.strokeStart ?? -1, 0.12 / 0.62, tolerance: 1e-3))
        #expect(approx(border.components[RenderStyleComponent.self]?.opacity ?? -1, 1, tolerance: 1e-3))

        // Just before the end: nothing left to draw — the window has zero width.
        scene.seek(to: 0.9999)
        guard let late = border.components[PathComponent.self] else {
            Issue.record("expected the border just before the clip end")
            return
        }
        #expect(approx(late.strokeProgress, 1, tolerance: 1e-3))
        #expect(approx(late.strokeStart, 1, tolerance: 1e-3))

        // Past the end the border leaves the scene.
        scene.seek(to: 1.1)
        #expect(scene.entities.count == 1)
        #expect(scene.entities[0] === subject)
    }

    @Test func fadedToNothingAtTheEnd() {
        let scene = Scene()
        let subject = Circle()
        scene.add(subject)
        scene.play(.highlight(subject), for: 1.s, easing: .linear)

        scene.seek(to: 0.9999)
        guard let border = scene.entities.first(where: { $0 !== subject }),
              let style = border.components[RenderStyleComponent.self] else {
            Issue.record("expected the border just before the clip end")
            return
        }
        // Fully drawn but invisible: the fade has run its course.
        #expect(approx(border.components[PathComponent.self]?.strokeProgress ?? -1, 1, tolerance: 1e-3))
        #expect(approx(style.opacity, 0, tolerance: 1e-3))
    }
}
