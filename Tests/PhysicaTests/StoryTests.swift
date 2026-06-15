import Testing
@testable import Physica

@Suite @MainActor struct StoryTests {
    private let tolerance: Real = 1e-4

    /// A two-slide story: slide 0 = add + two 1s moves (boundaries 0,1,2);
    /// slide 1 = add + one 2s move (boundaries 2,4). Total 4s.
    private func makeStory() -> (Scene, Story, Circle, Circle) {
        let scene = Scene()
        let story = Story(scene: scene)
        let a = Circle(radius: 0.3)
        let b = Circle(radius: 0.3)
        story.slide("one") { s in
            s.add(a)
            s.play(a.move(to: Position(2, 0, 0)), for: 1.s)
            s.play(a.move(to: Position(0, 0, 0)), for: 1.s)
        }
        story.slide("two") { s in
            s.add(b)
            s.play(b.move(to: Position(0, 3, 0)), for: 2.s)
        }
        return (scene, story, a, b)
    }

    private func runTweens(_ player: StoryPlayer, maxTicks: Int = 1000) {
        var ticks = 0
        while player.isTweening && ticks < maxTicks {
            player.tick(deltaTime: 0.1)
            ticks += 1
        }
    }

    @Test func slidesRecordTimeRanges() {
        let (_, story, _, _) = makeStory()
        #expect(story.slides.count == 2)
        #expect(abs(story.slides[0].startTime - 0) < tolerance)
        #expect(abs(story.slides[0].endTime - 2) < tolerance)
        #expect(abs(story.slides[1].startTime - 2) < tolerance)
        #expect(abs(story.slides[1].endTime - 4) < tolerance)
    }

    @Test func stepBoundariesDedupeZeroDurationClips() {
        let (_, story, _, _) = makeStory()
        // The 0-duration `add` clips collapse — no duplicate boundary at the start.
        #expect(story.slides[0].stepBoundaries == [0, 1, 2])
        #expect(story.slides[1].stepBoundaries == [2, 4])
    }

    @Test func actionsRegisterAndReplace() {
        let (_, story, _, _) = makeStory()
        story.action("Show components", id: "components") { _ in }
        story.action("Reset") { _ in }
        #expect(story.actionList.map(\.id) == ["components", "Reset"])
        // Same id replaces in place (no duplicate).
        story.action("Show components v2", id: "components") { _ in }
        #expect(story.actionList.map(\.id) == ["components", "Reset"])
        #expect(story.actionList[0].label == "Show components v2")
    }

    @Test func scrubGlobalProgressMapsToTime() {
        let (scene, story, _, _) = makeStory()
        let player = StoryPlayer(story: story)
        player.scrub(globalProgress: 0.5)
        #expect(abs(scene.timeline.currentTime - 2) < tolerance)
        player.scrub(globalProgress: 0.25)
        #expect(abs(scene.timeline.currentTime - 1) < tolerance)
    }

    @Test func scrubWithinSlideMapsToSlideRange() {
        let (scene, story, _, _) = makeStory()
        let player = StoryPlayer(story: story)
        player.scrub(slide: 1, progress: 0.5)
        #expect(abs(scene.timeline.currentTime - 3) < tolerance) // 2 + 0.5 * 2
    }

    @Test func nextStepTweenStopsExactlyOnBoundary() {
        let (scene, story, _, _) = makeStory()
        let player = StoryPlayer(story: story)
        player.nextStep()
        #expect(player.isTweening)
        runTweens(player)
        #expect(!player.isTweening)
        #expect(abs(scene.timeline.currentTime - 1) < tolerance) // no overshoot
    }

    /// Regression: a tween that creeps to within the seek-dedup epsilon (1e-4) of
    /// its target must still land *exactly* on the boundary. Pre-fix the final
    /// snap was deduped, stranding the playhead ~5e-5 short; `nextStep` then
    /// re-targeted the same boundary and its snap was deduped too, so Right-arrow
    /// stepping stuck forever (intermittent in the browser — frame-time jitter
    /// decides whether a tween lands inside the dead zone).
    @Test func stepLandsExactlyEvenWhenApproachingWithinSeekEpsilon() {
        let (scene, story, _, _) = makeStory()
        let player = StoryPlayer(story: story)
        player.nextStep()                      // tween 0 → boundary 1
        player.tick(deltaTime: 0.499975)       // 2 × 0.499975 = 0.99995 (within 1e-4 of 1)
        player.tick(deltaTime: 1.0)            // overshoots → clamps to 1 → must snap exactly
        #expect(!player.isTweening)
        #expect(abs(scene.timeline.currentTime - 1) < 1e-6)   // exact, not 0.99995

        // The next step must advance to boundary 2, not re-stick on 1.
        player.nextStep()
        runTweens(player)
        #expect(abs(scene.timeline.currentTime - 2) < tolerance)
    }

    @Test func previousStepIsInstant() {
        let (scene, story, _, _) = makeStory()
        let player = StoryPlayer(story: story)
        player.scrub(globalProgress: 0.375) // time 1.5
        player.previousStep()
        #expect(!player.isTweening)          // no tween — instant
        #expect(abs(scene.timeline.currentTime - 1) < tolerance)
    }

    @Test func nextStepRollsOverIntoNextSlide() {
        let (scene, story, _, _) = makeStory()
        let player = StoryPlayer(story: story)
        player.scrub(globalProgress: 0.25) // time 1, still slide 0
        #expect(player.currentSlideIndex == 0)
        player.nextStep()                   // → boundary 2 == slide 1 start
        runTweens(player)
        #expect(abs(scene.timeline.currentTime - 2) < tolerance)
        #expect(player.currentSlideIndex == 1)
    }

    @Test func nextSlideTweensIntoNextSlide() {
        let (scene, story, _, _) = makeStory()
        let player = StoryPlayer(story: story)
        player.nextSlide()
        #expect(player.isTweening)
        runTweens(player)
        #expect(player.currentSlideIndex == 1)
        #expect(abs(scene.timeline.currentTime - 2) < tolerance) // lands at slide 1's start
    }

    @Test func previousSlideIsInstant() {
        let (scene, story, _, _) = makeStory()
        let player = StoryPlayer(story: story)
        player.scrub(globalProgress: 0.75) // time 3, slide 1
        #expect(player.currentSlideIndex == 1)
        player.previousSlide()
        #expect(!player.isTweening)
        #expect(abs(scene.timeline.currentTime - 0) < tolerance) // slide 0 start
        #expect(player.currentSlideIndex == 0)
    }

    @Test func backwardScrubRewindsLaterSlideEntities() {
        let (scene, story, a, b) = makeStory()
        let player = StoryPlayer(story: story)
        player.scrub(globalProgress: 1.0) // time 4 — everything present (persists by default)
        #expect(scene.entities.contains { $0 === b })
        player.scrub(globalProgress: 0.0) // back to start
        #expect(!scene.entities.contains { $0 === b }) // slide-1 add rewound
        #expect(scene.entities.contains { $0 === a })  // slide-0 add still applied
    }

    @Test func clearRemovesSpecificEntitiesScrubSafely() {
        let scene = Scene()
        let story = Story(scene: scene)
        let a = Circle(radius: 0.2)
        let b = Circle(radius: 0.2)
        story.slide("one") { s in
            s.add(a, b)
            s.play(a.move(to: Position(1, 0, 0)), for: 1.s)
        }
        story.slide("two") { s in
            s.clear(a)                                       // drop just `a`; `b` persists
            s.play(s.frame.shift(Position(1, 0, 0)), for: 1.s)
        }
        let player = StoryPlayer(story: story)
        player.scrub(slide: 1, progress: 0.5)
        #expect(!scene.entities.contains { $0 === a })       // cleared
        #expect(scene.entities.contains { $0 === b })        // persists (default)
        player.scrub(slide: 0, progress: 0.5)
        #expect(scene.entities.contains { $0 === a })        // scrub back re-inserts
    }

    @Test func clearAllDefersToNextSlideKeepingGlobals() {
        let scene = Scene()
        let story = Story(scene: scene)
        let bar = Rectangle(width: 1, height: 0.2)   // global (added before slides)
        let note = Circle(radius: 0.2)               // slide content
        scene.add(bar)
        story.slide("one") { s in
            s.add(note)
            s.play(note.move(to: Position(1, 0, 0)), for: 1.s)
            s.clear()                                     // deferred — fires at slide two
        }
        story.slide("two") { s in
            s.play(s.frame.shift(Position(1, 0, 0)), for: 1.s)
        }
        let player = StoryPlayer(story: story)
        player.scrub(slide: 0, progress: 0.5)
        #expect(scene.entities.contains { $0 === note })     // deferred: still present in slide one
        player.scrub(slide: 1, progress: 0.5)
        #expect(!scene.entities.contains { $0 === note })    // fires entering slide two
        #expect(scene.entities.contains { $0 === bar })      // global kept
        player.scrub(slide: 0, progress: 0.5)
        #expect(scene.entities.contains { $0 === note })     // scrub back re-inserts
    }

    @Test func addLastStateReaddsPreviousSlideOnlyOneStep() {
        let scene = Scene()
        let story = Story(scene: scene)
        let token = Circle(radius: 0.2)
        story.slide("intro") { s in
            s.add(token)
            s.play(token.move(to: Position(1, 0, 0)), for: 1.s)
            s.clear()                                     // deferred — clears `token` entering keep
        }
        story.slide("keep") { s in
            s.addLastState()                                 // re-pull intro's `token` after the clear
            s.play(s.frame.shift(Position(1, 0, 0)), for: 1.s)
            s.clear()                                     // deferred — clears it again entering drop
        }
        story.slide("drop") { s in
            s.play(s.frame.shift(Position(1, 0, 0)), for: 1.s)   // no addLastState
        }
        let player = StoryPlayer(story: story)
        player.scrub(slide: 1, progress: 0.5)
        #expect(scene.entities.contains { $0 === token })    // re-added one step forward
        player.scrub(slide: 2, progress: 0.5)
        #expect(!scene.entities.contains { $0 === token })   // not carried transitively
    }

    @Test func subEpsilonScrubIsDeduped() {
        let (scene, story, _, _) = makeStory()
        let player = StoryPlayer(story: story)
        player.scrub(globalProgress: 0.5)
        let settled = scene.timeline.currentTime
        // A scroll delta below the seek epsilon must not move the playhead.
        player.scrub(globalProgress: 0.5 + Real(1e-6))
        #expect(scene.timeline.currentTime == settled)
    }

    @Test func stateReflectsSlideAndProgress() {
        let (_, story, _, _) = makeStory()
        let player = StoryPlayer(story: story)
        player.scrub(globalProgress: 0.125) // time 0.5, slide 0 (duration 2)
        let state = player.state
        #expect(state.slideIndex == 0)
        #expect(abs(state.slideProgress - 0.25) < tolerance)
        #expect(abs(state.time - 0.5) < tolerance)
    }

    @Test func crossSlideScrubInterruptsInteractionsAndDrag() {
        let (scene, story, a, _) = makeStory()
        let player = StoryPlayer(story: story)

        // An interaction in flight.
        let c = Circle(radius: 0.2)
        scene.interact(.draw(c), for: 1.s)
        #expect(!scene.interactions.isIdle)

        // A drag in flight on `a` (resting at the origin at t = 0).
        a.components[DraggableComponent.self] = DraggableComponent(payload: .tag("a"))
        scene.dispatch(.pointerDown(.zero))
        scene.dispatch(.pointerMoved(Position(0.4, 0, 0)))
        #expect(scene.drag.debugString != "drag idle")

        player.scrub(globalProgress: 0.75) // cross into slide 1
        #expect(scene.interactions.isIdle)            // interruptAll
        #expect(scene.drag.debugString == "drag idle") // cancelActive
    }

    @Test func triggerRunsRegisteredAction() {
        let (scene, story, _, _) = makeStory()
        let shape = Circle(radius: 0.4)
        story.action("Reveal", id: "reveal") { s in
            s.interact(.draw(shape), for: 0.5.s)
        }
        let player = StoryPlayer(story: story)
        #expect(!scene.entities.contains { $0 === shape })
        player.trigger(actionID: "reveal")
        // `.draw` introduces its target at clip begin — visible immediately.
        #expect(scene.entities.contains { $0 === shape })
    }

    @Test func onSlideChangedHookFiresWithIndices() {
        let (_, story, _, _) = makeStory()
        var changes: [(from: Int, to: Int)] = []
        story.onSlideChanged = { from, to in changes.append((from, to)) }
        let player = StoryPlayer(story: story)
        player.scrub(globalProgress: 0.75) // 0 → 3, crosses into slide 1
        #expect(changes.count == 1)
        #expect(changes.first?.from == 0)
        #expect(changes.first?.to == 1)
        // A scrub within the same slide does not re-fire it.
        player.scrub(slide: 1, progress: 0.75)
        #expect(changes.count == 1)
    }

    @Test func eventStreamDeliversSlideChanged() async {
        let (_, story, _, _) = makeStory()
        let player = StoryPlayer(story: story)
        let stream = player.eventStream()
        player.scrub(globalProgress: 0.75) // 0 → 3, crosses into slide 1

        var events: [StoryEvent] = []
        for await event in stream {
            events.append(event)
            if events.count == 1 { break }
        }
        #expect(events[0] == .slideChanged(from: 0, to: 1))
    }

    @Test func cameraTransitionIsScrubbable() {
        let scene = Scene()
        let story = Story(scene: scene)
        let dot = Circle(radius: 0.2)
        story.slide("cam") { s in
            s.add(dot)
            s.play(s.frame.shift(Position(6, 0, 0)), for: 1.s)
        }
        let player = StoryPlayer(story: story)
        player.scrub(slide: 0, progress: 0.5)
        // Smoothstep(0.5) = 0.5, so the camera sits halfway along the shift.
        #expect(abs(scene.camera.transform.position.x - 3) < 0.2)
        #expect(abs(scene.camera.transform.position.z - 10) < tolerance) // shift keeps z
    }
}
