// Facade host tests — the platform-neutral half of the `Storytelling {}`
// facade: FontBook role resolution, the degraded `Text()` path, the
// `Slide(...)`/`@StoryBuilder` authoring elements, and the `ExitTransition`
// wiring through `Story.slide` (fade-out as the slide's final beat, scrub-safe
// both ways). The auto-mount itself is WASI-only and verified by the wasm
// smoke drill.

import Testing
@testable import PhysicaFoundation
@testable import PhysicaAlgebra
@testable import PhysicaTypesetting
@testable import PhysicaKernel
@testable import PhysicaCharts
@testable import PhysicaPhysics
@testable import PhysicaEquationGame

@Suite @MainActor struct FacadeTests {
    private let tolerance: Real = 1e-4

    private func opacity(_ entity: Entity) -> Real {
        entity.components[RenderStyleComponent.self]?.opacity ?? 1
    }

    // MARK: FontBook + Text

    @Test func fontBookResolvesRoleSizesWithoutAFace() {
        FontBook.reset()
        let title = FontBook.resolve(.title)
        #expect(title.font == nil)
        #expect(abs(title.size - 1.2) < tolerance)
        #expect(abs(FontBook.resolve(.body).size - 0.5) < tolerance)
        #expect(abs(FontBook.resolve(.caption).size - 0.35) < tolerance)
    }

    @Test func textDegradesToEmptyGlyphsWithoutAFace() {
        FontBook.reset()
        let title = Text("Hello, World!", font: .title)
        #expect(title.textComponent.glyphs.isEmpty)
        #expect(title.name == "Hello, World!")
        #expect(abs(title.textComponent.fontSize - 1.2) < tolerance)
        // The degraded entity still composes with the animation surface.
        let animation = title.write()
        #expect(animation.pairs.count == 1)
    }

    // MARK: Slide + StoryBuilder

    @Test func builderCollectsSlideSpellings() {
        @StoryBuilder @MainActor func make() -> [SlideSpec] {
            Slide("named") { _ in }
            Slide(onAppear: nil, onDisappear: .fadeOut) { _ in }
            Slide { _ in }
        }
        let specs = make()
        #expect(specs.count == 3)
        #expect(specs[0].title == "named")
        #expect(specs[0].onDisappear == nil)
        #expect(specs[1].onDisappear != nil)
        #expect(specs[2].title.isEmpty)
    }

    // MARK: ExitTransition wiring

    @Test func fadeOutExitIsTheSlidesFinalBeatAndScrubsBack() {
        let scene = Scene()
        let story = Story(scene: scene)
        let a = Circle(radius: 0.3)

        let record = story.slide(Slide("one", onDisappear: .fadeOut) { s in
            s.add(a)
            s.play(a.move(to: Position(1, 0, 0)), for: 1.s)
        })
        story.slide("two") { s in
            s.wait(0.5.s)
        }

        // 1s move + 0.6s fade = the slide's range; the fade is its own beat.
        #expect(abs(record.endTime - 1.6) < tolerance)
        #expect(record.stepBoundaries.count == 3)

        scene.seek(to: 1.0)                       // fully built, fade not started
        #expect(abs(opacity(a) - 1) < tolerance)
        scene.seek(to: 1.6)                       // fade complete
        #expect(opacity(a) < 0.01)
        scene.seek(to: 1.7)                       // past the boundary clear
        #expect(!scene.contains(a))
        scene.seek(to: 0.5)                       // scrub back: restored, visible
        #expect(scene.contains(a))
        #expect(abs(opacity(a) - 1) < tolerance)
    }

    @Test func zoomOutExitShrinksWhileFading() {
        let scene = Scene()
        let story = Story(scene: scene)
        let a = Circle(radius: 0.3)

        let record = story.slide(Slide("one", onDisappear: .zoomOut) { s in
            s.add(a)
            s.play(a.move(to: Position(1, 0, 0)), for: 1.s)
        })

        scene.seek(to: record.endTime)
        #expect(opacity(a) < 0.01)
        #expect(abs(a.transform.scale.x - 0.05) < tolerance)
        scene.seek(to: 0.2)
        #expect(abs(a.transform.scale.x - 1) < tolerance)
    }

    @Test func clearExitAddsNoClip() {
        let scene = Scene()
        let story = Story(scene: scene)
        let a = Circle(radius: 0.3)

        let record = story.slide(Slide("one") { s in
            s.add(a)
            s.play(a.move(to: Position(1, 0, 0)), for: 1.s)
        })
        #expect(abs(record.endTime - 1.0) < tolerance)
        #expect(record.stepBoundaries.count == 2)
    }

    @Test func specConvenienceMatchesDirectSlideCall() {
        let scene = Scene()
        let story = Story(scene: scene)
        let a = Circle(radius: 0.3)
        let record = story.slide(Slide("via spec") { s in
            s.add(a)
            s.play(a.move(to: Position(0, 1, 0)), for: 2.s)
        })
        #expect(record.title == "via spec")
        #expect(abs(record.duration - 2.0) < tolerance)
    }
}
