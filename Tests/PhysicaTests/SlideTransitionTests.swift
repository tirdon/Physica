import Testing
@testable import Physica

@Suite @MainActor struct SlideTransitionTests {
    private let tolerance: Real = 1e-4

    private func overlay(_ scene: Scene) -> Entity? {
        scene.entities.first { $0.name == "transition" }
    }

    private func opacity(_ entity: Entity) -> Real {
        entity.components[RenderStyleComponent.self]?.opacity ?? -1
    }

    // MARK: Structure

    @Test func noneTransitionAddsNoClip() {
        let scene = Scene()
        let story = Story(scene: scene)
        story.slide("a") { s in s.play(s.frame.shift(Position(1, 0, 0)), for: 1.s) }
        #expect(story.slides[0].stepBoundaries == [0, 1])
    }

    @Test func transitionIsTheSlidesFirstStep() {
        let scene = Scene()
        let story = Story(scene: scene)
        story.slide("a", transition: .push(from: .left)) { s in
            s.play(s.frame.shift(Position(1, 0, 0)), for: 1.s)
        }
        // push (0.8s) is step 0; the author shift (1.0s) is step 1.
        let bounds = story.slides[0].stepBoundaries
        #expect(bounds.count == 3)
        #expect(abs(bounds[0] - 0) < tolerance)
        #expect(abs(bounds[1] - 0.8) < tolerance)
        #expect(abs(bounds[2] - 1.8) < tolerance)
    }

    // MARK: Fade overlay (scrub-safe transient quad)

    @Test func fadeOverlayAppearsMidWindowThenLeaves() {
        let scene = Scene()
        let story = Story(scene: scene)
        let base = Circle(radius: 0.3)
        story.slide("intro") { s in
            s.add(base)
            s.play(base.move(to: Position(1, 0, 0)), for: 1.s)   // slide 0: [0, 1]
        }
        story.slide("focus", transition: .fade()) { s in
            s.play(s.frame.shift(Position(2, 0, 0)), for: 1.s)   // slide 1: fade(0.7)+shift(1) = [1, 2.7]
        }
        let player = StoryPlayer(story: story)

        // Before the fade clip (slide 0): no overlay on the board.
        player.scrub(slide: 0, progress: 0.5)
        #expect(overlay(scene) == nil)

        // Mid-fade (time 1.35 → 0.35 into the 0.7s window): present, partly clear.
        player.scrub(slide: 1, progress: 0.35 / 1.7)
        let mid = try! #require(overlay(scene))
        let op = opacity(mid)
        #expect(op > 0.01 && op < 0.99)

        // Past the fade window (time 2.0): removed.
        player.scrub(slide: 1, progress: 1.0 / 1.7)
        #expect(overlay(scene) == nil)

        // Scrub back across the boundary: still gone.
        player.scrub(slide: 0, progress: 0.5)
        #expect(overlay(scene) == nil)
    }

    @Test func fadeOverlayNotCarriedForward() {
        let scene = Scene()
        let story = Story(scene: scene)
        let token = Circle(radius: 0.2)
        story.slide("one", transition: .fade()) { s in
            s.add(token)
            s.play(token.move(to: Position(1, 0, 0)), for: 1.s)
            s.carry(token)   // carry token; the fade overlay is transient, not carried
        }
        story.slide("two") { s in
            s.play(s.frame.shift(Position(1, 0, 0)), for: 1.s)
        }
        let player = StoryPlayer(story: story)
        player.scrub(slide: 1, progress: 0.5)
        #expect(scene.entities.contains { $0 === token })          // carried forward
        #expect(!scene.entities.contains { $0.name == "transition" }) // transient overlay is not
    }

    // MARK: Camera push / zoom (ride the SceneCamera proxy)

    @Test func pushTransitionMovesCameraAndRewinds() {
        let scene = Scene()
        let story = Story(scene: scene)
        story.slide("a") { s in s.play(s.frame.shift(Position(0, 1, 0)), for: 1.s) }   // [0, 1]
        story.slide("b", transition: .push(from: .right)) { _ in }                     // [1, 1.8]
        let frameWidth = scene.frameBounds.size.x
        let player = StoryPlayer(story: story)

        // At the slide start the camera is offset one frame toward the edge.
        player.scrub(slide: 1, progress: 0.0)
        #expect(abs(scene.camera.transform.position.x - frameWidth) < 0.3)

        // Eased to rest by the end of the push.
        player.scrub(slide: 1, progress: 1.0)
        #expect(abs(scene.camera.transform.position.x) < 0.05)

        // Rewinding before the slide restores the resting camera.
        player.scrub(slide: 0, progress: 0.3)
        #expect(abs(scene.camera.transform.position.x) < tolerance)
    }

    @Test func zoomTransitionEasesToRestAndRewinds() {
        let scene = Scene()
        let story = Story(scene: scene)
        story.slide("a") { s in s.play(s.frame.shift(Position(0, 1, 0)), for: 1.s) }   // [0, 1]
        story.slide("z", transition: .zoom(from: 14)) { _ in }                         // [1, 1.8]
        let rest = scene.frame.zoomExtent
        let player = StoryPlayer(story: story)

        player.scrub(slide: 1, progress: 0.0)
        #expect(abs(scene.frame.zoomExtent - 14) < 0.3)

        player.scrub(slide: 1, progress: 1.0)
        #expect(abs(scene.frame.zoomExtent - rest) < 0.05)

        player.scrub(slide: 0, progress: 0.3)
        #expect(abs(scene.frame.zoomExtent - rest) < tolerance)
    }
}
