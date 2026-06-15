import Testing
@testable import Physica

@Suite @MainActor struct StoryTests {
    private let tolerance: Real = 1e-4

    /// A two-slide story: slide 0 = add + two 1s moves (boundaries 0,1,2);
    /// slide 1 = add + one 2s move (boundaries 2,4). Total 4s. Slide 0 carries `a`
    /// so its content persists into slide 1 — a clean boundary (no auto-clear), the
    /// common "build up across slides" shape.
    private func makeStory(options: StoryOptions = StoryOptions()) -> (Scene, Story, Circle, Circle) {
        let scene = Scene()
        let story = Story(scene: scene, options: options)
        let a = Circle(radius: 0.3)
        let b = Circle(radius: 0.3)
        story.slide("one") { s in
            s.add(a)
            s.carry(a)
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

    private func runAutoplay(_ player: StoryPlayer, maxTicks: Int = 5000) {
        var ticks = 0
        while player.isAutoplaying && ticks < maxTicks {
            player.tick(deltaTime: 0.05)
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
        // Clean carry-boundary: slide 0's fully-built end coincides with slide 1's
        // start (its content carried), so Down rests at t = 2 either way.
        #expect(abs(scene.timeline.currentTime - 2) < tolerance)
    }

    /// Down on a *deferred-clear* slide rests at its fully-built end (one nudge
    /// before its content clears at the boundary), not the bare next-slide start.
    /// That is the rest Right-stepping settles on too — regression for "Down lands
    /// on the start of the new slide instead of the end of the slide".
    @Test func nextSlideRestsAtDeferredClearEnd() {
        let scene = Scene()
        let story = Story(scene: scene)
        let a = Circle(radius: 0.3)
        let b = Circle(radius: 0.3)
        story.slide("one") { s in
            s.add(a)                                        // own content, not carried → auto-clears
            s.play(a.move(to: Position(2, 0, 0)), for: 1.s)
        }
        story.slide("two") { s in
            s.add(b)
            s.play(b.move(to: Position(0, 3, 0)), for: 1.s)
        }
        #expect(story.slides[0].deferredClear)              // `a` clears into slide 1
        let player = StoryPlayer(story: story)
        player.nextSlide()
        runTweens(player)
        // Rests just *before* the slide-0/1 boundary at t = 1, still on slide 0 with
        // `a` shown — not at t = 1 where slide 1 starts and `a` has cleared.
        #expect(player.currentSlideIndex == 0)
        #expect(scene.timeline.currentTime < 1)
        #expect(abs(scene.timeline.currentTime - 1) < 0.01)
        #expect(scene.entities.contains { $0 === a })
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
            s.carry(a, b)                                    // both persist past slide one
            s.play(a.move(to: Position(1, 0, 0)), for: 1.s)
        }
        story.slide("two") { s in
            s.clear(a)                                       // drop just `a`; `b` stays
            s.play(s.frame.shift(Position(1, 0, 0)), for: 1.s)
        }
        let player = StoryPlayer(story: story)
        player.scrub(slide: 1, progress: 0.5)
        #expect(!scene.entities.contains { $0 === a })       // explicitly cleared
        #expect(scene.entities.contains { $0 === b })        // carried, untouched
        player.scrub(slide: 0, progress: 0.5)
        #expect(scene.entities.contains { $0 === a })        // scrub back re-inserts
    }

    @Test func slideContentAutoClearsKeepingGlobals() {
        let scene = Scene()
        let story = Story(scene: scene)
        let bar = Rectangle(width: 1, height: 0.2)   // global (added before slides)
        let note = Circle(radius: 0.2)               // slide content (auto-clears)
        scene.add(bar)
        story.slide("one") { s in
            s.add(note)
            s.play(note.move(to: Position(1, 0, 0)), for: 1.s)
        }
        story.slide("two") { s in
            s.play(s.frame.shift(Position(1, 0, 0)), for: 1.s)
        }
        let player = StoryPlayer(story: story)
        player.scrub(slide: 0, progress: 0.5)
        #expect(scene.entities.contains { $0 === note })     // visible through slide one
        player.scrub(slide: 1, progress: 0.5)
        #expect(!scene.entities.contains { $0 === note })    // auto-cleared entering slide two
        #expect(scene.entities.contains { $0 === bar })      // global kept
        player.scrub(slide: 0, progress: 0.5)
        #expect(scene.entities.contains { $0 === note })     // scrub back re-inserts
    }

    @Test func carryPersistsContentForwardUntilCleared() {
        let scene = Scene()
        let story = Story(scene: scene)
        let token = Circle(radius: 0.2)
        story.slide("intro") { s in
            s.add(token)
            s.play(token.move(to: Position(1, 0, 0)), for: 1.s)
            s.carry(token)                                // opt out of intro's auto-clear
        }
        story.slide("keep") { s in
            s.play(s.frame.shift(Position(1, 0, 0)), for: 1.s)   // token persists, untouched
            s.clear(token)                                // explicit removal entering drop
        }
        story.slide("drop") { s in
            s.play(s.frame.shift(Position(1, 0, 0)), for: 1.s)
        }
        let player = StoryPlayer(story: story)
        player.scrub(slide: 1, progress: 0.5)
        #expect(scene.entities.contains { $0 === token })    // carried into "keep"
        player.scrub(slide: 2, progress: 0.5)
        #expect(!scene.entities.contains { $0 === token })   // explicit clear dropped it
        player.scrub(slide: 0, progress: 0.5)
        #expect(scene.entities.contains { $0 === token })    // scrub back re-inserts
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

    // MARK: Autoplay

    @Test func autoplayDwellsBeforeFirstAdvance() {
        let (scene, story, _, _) = makeStory(options: StoryOptions(autoplayDwell: 1.0))
        let player = StoryPlayer(story: story)
        player.play()
        #expect(player.isAutoplaying)
        player.tick(deltaTime: 0.5)              // half the dwell — still resting at t = 0
        #expect(!player.isTweening)
        #expect(abs(scene.timeline.currentTime - 0) < tolerance)
        player.tick(deltaTime: 0.6)              // dwell elapsed → begins advancing
        #expect(player.isTweening)
    }

    @Test func autoplayAdvancesThroughAllBeatsThenStops() {
        let (scene, story, _, _) = makeStory(options: StoryOptions(autoplayDwell: 0.2))
        let player = StoryPlayer(story: story)
        player.play()
        runAutoplay(player)
        #expect(!player.isAutoplaying)                          // stopped at the last beat (no loop)
        #expect(abs(scene.timeline.currentTime - 4) < tolerance) // beats end at t = 4
        #expect(player.currentSlideIndex == 1)
    }

    @Test func pausePreventsAutoplayAdvance() {
        let (scene, story, _, _) = makeStory(options: StoryOptions(autoplayDwell: 0.2))
        let player = StoryPlayer(story: story)
        player.play()
        player.pause()
        #expect(!player.isAutoplaying)
        for _ in 0..<100 { player.tick(deltaTime: 0.1) }        // long after the dwell would elapse
        #expect(!player.isTweening)
        #expect(abs(scene.timeline.currentTime - 0) < tolerance) // never advanced
    }

    @Test func autoplayFinishedEventFiresAtEnd() async {
        let (_, story, _, _) = makeStory(options: StoryOptions(autoplayDwell: 0.1))
        let player = StoryPlayer(story: story)
        let stream = player.eventStream()
        player.play()
        runAutoplay(player)
        var sawFinished = false
        for await event in stream {
            if event == .autoplayFinished { sawFinished = true; break }
        }
        #expect(sawFinished)
    }

    @Test func autoplayLoopsBackToStart() {
        let (scene, story, _, _) = makeStory(options: StoryOptions(autoplayDwell: 0.2, autoplayLoops: true))
        let player = StoryPlayer(story: story)
        player.play()
        var reachedEnd = false
        var wrapped = false
        for _ in 0..<3000 {
            player.tick(deltaTime: 0.05)
            if abs(scene.timeline.currentTime - 4) < 0.05 { reachedEnd = true }
            if reachedEnd && scene.timeline.currentTime < 1 { wrapped = true }
        }
        #expect(player.isAutoplaying)   // looping never stops on its own
        #expect(wrapped)                // ran to the end, then restarted from the top
    }

    // MARK: Narration captions

    @Test func captionsActivateByTimeRange() {
        let scene = Scene()
        let story = Story(scene: scene)
        let a = Circle(radius: 0.2)
        let b = Circle(radius: 0.2)
        story.slide("one") { s in
            story.caption("first beat")                       // recorded at t = 0
            s.add(a)
            s.play(a.move(to: Position(1, 0, 0)), for: 1.s)
            story.caption("second beat")                      // recorded at t = 1
            s.play(a.move(to: Position(2, 0, 0)), for: 1.s)
        }
        story.slide("two") { s in
            story.caption("third beat")                       // recorded at t = 2
            s.add(b)
            s.play(b.move(to: Position(0, 1, 0)), for: 1.s)
        }
        #expect(story.caption(at: -1) == "")                  // nothing before the first
        #expect(story.caption(at: 0.5) == "first beat")
        #expect(story.caption(at: 1.5) == "second beat")
        #expect(story.caption(at: 2.5) == "third beat")

        let player = StoryPlayer(story: story)
        player.scrub(globalProgress: 0)
        #expect(player.currentCaption == "first beat")
        player.scrub(slide: 1, progress: 0.5)                 // t = 2.5
        #expect(player.currentCaption == "third beat")
    }

    @Test func captionBlanksWithEmptyString() {
        let scene = Scene()
        let story = Story(scene: scene)
        let a = Circle(radius: 0.2)
        story.slide("one") { s in
            story.caption("shown")
            s.add(a)
            s.play(a.move(to: Position(1, 0, 0)), for: 1.s)
            story.caption("")                                 // blank the band at t = 1
            s.play(a.move(to: Position(2, 0, 0)), for: 1.s)
        }
        #expect(story.caption(at: 0.5) == "shown")
        #expect(story.caption(at: 1.5) == "")                 // cleared
    }

    /// A slide's opening caption must anchor to the slide's *start* and show
    /// through an arrival transition, even though the transition clip (here a 0.8s
    /// `.push`) advances the live time before the caption call runs. Regression:
    /// the caption used to stamp at the slide's end, bleeding into the next slide.
    @Test func openingCaptionAnchorsThroughEntranceTransition() {
        let scene = Scene()
        let story = Story(scene: scene)
        let a = Circle(radius: 0.2)
        let b = Circle(radius: 0.2)
        b.position = .zero
        story.slide("first") { s in
            story.caption("first")
            s.add(a)
            s.play(a.move(to: Position(1, 0, 0)), for: 1.s)   // [0, 1]
        }
        story.slide("second", transition: .push(from: .right)) { s in
            story.caption("second")                           // after the 0.8s push enqueue
            s.add(b)
        }
        #expect(abs(story.slides[1].startTime - 1) < tolerance)
        #expect(story.caption(at: 1.0 + 1e-3) == "second")    // active from the slide start…
        #expect(story.caption(at: 1.4) == "second")           // …through the slide-in, not after it
    }

    // MARK: Content-entrance transition (`.push`)

    /// Two slides; slide 1 is a content entrance. Slide 0 owns `prev` (auto-clears
    /// into slide 1, so it is deferred-clear — the demo's Forces→Solve shape).
    /// `incoming` rests at the origin and slides in from the right over slide 0.
    private func makePushStory() -> (Scene, Story, Circle, Circle) {
        let scene = Scene()
        let story = Story(scene: scene)
        let prev = Circle(radius: 0.3)
        let incoming = Circle(radius: 0.3)
        incoming.position = Position(0, 0, 0)
        story.slide("first") { s in
            s.add(prev)
            s.play(prev.move(to: Position(2, 0, 0)), for: 1.s)   // slide 0: [0, 1]
        }
        story.slide("second", transition: .push(from: .right)) { s in
            s.add(incoming)                                       // carried in by the slide-in
        }
        return (scene, story, prev, incoming)
    }

    @Test func pushSlideIsMarkedEntranceAndAddsSlideInTime() {
        let (_, story, _, _) = makePushStory()
        #expect(!story.slides[0].entranceTransition)
        #expect(story.slides[1].entranceTransition)
        // The 0.8s slide-in sits ahead of the (0-duration) content add.
        #expect(abs(story.slides[1].startTime - 1) < tolerance)
        #expect(abs(story.slides[1].endTime - 1.8) < tolerance)
        #expect(story.slides[1].stepBoundaries.count == 2)
        #expect(abs(story.slides[1].stepBoundaries[1] - 1.8) < tolerance)
    }

    @Test func pushContentSlidesInOverVisiblePrevious() {
        let (scene, story, prev, incoming) = makePushStory()
        let player = StoryPlayer(story: story)
        player.scrub(slide: 1, progress: 0.5)               // halfway through the slide-in (t = 1.4)
        #expect(scene.entities.contains { $0 === incoming })  // on the board while sliding
        #expect(scene.entities.contains { $0 === prev })      // previous board still underneath
        #expect(incoming.position.x > 0.1)                    // travelling in from the right, not yet home
    }

    @Test func pushContentLandsAtRestAndClearsPrevious() {
        let (scene, story, prev, incoming) = makePushStory()
        let player = StoryPlayer(story: story)
        player.nextSlide(); runTweens(player)               // Down → slide 0's built end (deferred)
        #expect(player.currentSlideIndex == 0)
        player.nextSlide(); runTweens(player)               // Down → slide 1, slide-in plays in the tween
        #expect(player.currentSlideIndex == 1)
        #expect(abs(incoming.position.x) < tolerance)         // landed exactly at rest
        #expect(scene.entities.contains { $0 === incoming })
        #expect(!scene.entities.contains { $0 === prev })     // previous cleared once the slide-in landed
    }

    /// Right-stepping into a push slide skips its off-board step 0 and rests on the
    /// landed slide — the content is at rest, never parked off-screen.
    @Test func pushStepRestsOnLandedNotOffscreen() {
        let (scene, story, _, incoming) = makePushStory()
        let player = StoryPlayer(story: story)
        player.nextStep(); runTweens(player)                // → slide 0's deferred end
        #expect(player.currentSlideIndex == 0)
        player.nextStep(); runTweens(player)                // → slide 1, landed
        #expect(player.currentSlideIndex == 1)
        #expect(abs(incoming.position.x) < tolerance)
        #expect(scene.entities.contains { $0 === incoming })
    }

    @Test func pushSlideInIsScrubSafe() {
        let (scene, story, prev, incoming) = makePushStory()
        let player = StoryPlayer(story: story)
        player.scrub(globalProgress: 1.0)                   // end: incoming in, prev cleared
        #expect(scene.entities.contains { $0 === incoming })
        #expect(!scene.entities.contains { $0 === prev })
        player.scrub(globalProgress: 0.0)                   // back to the very start
        #expect(!scene.entities.contains { $0 === incoming }) // slide-in rewound
        #expect(scene.entities.contains { $0 === prev })      // previous restored
    }

    /// A *clean* boundary into a push slide: slide 0 carries its content (nothing to
    /// auto-clear), so its end coincides with the push slide's off-board slide-in
    /// start. The prior slide's built end must stay a reachable rest (one nudge
    /// before), and stepping must not stick.
    @Test func pushAfterCleanBoundaryKeepsPriorEndReachable() {
        let scene = Scene()
        let story = Story(scene: scene)
        let kept = Circle(radius: 0.3)
        let incoming = Circle(radius: 0.3)
        incoming.position = Position(0, 0, 0)
        story.slide("first") { s in
            s.add(kept)
            s.carry(kept)                                    // carried → slide 0 is a clean boundary
            s.play(kept.move(to: Position(2, 0, 0)), for: 1.s)
        }
        story.slide("second", transition: .push(from: .right)) { s in
            s.add(incoming)
        }
        #expect(!story.slides[0].deferredClear)
        #expect(story.slides[1].entranceTransition)
        let player = StoryPlayer(story: story)
        player.nextStep(); runTweens(player)                // → slide 0's built end (just before t = 1)
        #expect(player.currentSlideIndex == 0)
        #expect(scene.timeline.currentTime < 1)
        #expect(abs(scene.timeline.currentTime - 1) < 0.01)
        player.nextStep(); runTweens(player)                // → slide 1, landed (does not stick)
        #expect(player.currentSlideIndex == 1)
        #expect(abs(incoming.position.x) < tolerance)
    }

    // MARK: Content-morph transition (`.morph`)

    private func opacity(_ entity: Entity) -> Real {
        entity.components[RenderStyleComponent.self]?.opacity ?? 1
    }

    /// Slide 0 owns `from` (named "shape", auto-clears into slide 1 → a morph
    /// source). Slide 1 is a `.morph` and introduces `into` (same name) at a
    /// different pose, so the morph pairs them and tweens `into` from `from`'s pose.
    private func makeMorphStory() -> (Scene, Story, Circle, Rectangle) {
        let scene = Scene()
        let story = Story(scene: scene)
        let from = Circle(radius: 0.3)
        from.name = "shape"
        from.position = Position(-2, 0, 0)
        let into = Rectangle(width: 1, height: 1)
        into.name = "shape"
        into.position = Position(2, 1, 0)
        story.slide("first") { s in
            s.add(from)
            s.play(from.move(to: Position(-1, 0, 0)), for: 1.s)  // slide 0: [0, 1]
        }
        story.slide("second", transition: .morph()) { s in
            s.add(into)                                          // morph target, paired by name
        }
        return (scene, story, from, into)
    }

    @Test func morphSlideIsMarkedEntrance() {
        let (_, story, _, _) = makeMorphStory()
        #expect(!story.slides[0].entranceTransition)
        #expect(story.slides[1].entranceTransition)              // skips step 0, plays during arrival
        #expect(abs(story.slides[1].startTime - 1) < tolerance)
        #expect(abs(story.slides[1].endTime - 1.8) < tolerance)  // default 0.8s morph
    }

    @Test func morphMidwayInterpolatesPoseAndCrossfades() {
        let (scene, story, from, into) = makeMorphStory()
        let player = StoryPlayer(story: story)
        player.scrub(slide: 1, progress: 0.5)                    // t = 1.4, halfway through the morph
        #expect(scene.entities.contains { $0 === into })          // target inserted while morphing
        #expect(scene.entities.contains { $0 === from })          // source still present (clears at the end)
        // Pose lerps source(-1,0) → rest(2,1); smoothstep(0.5) = 0.5 → (0.5, 0.5).
        #expect(abs(into.position.x - 0.5) < 0.05)
        #expect(abs(into.position.y - 0.5) < 0.05)
        #expect(opacity(from) < 0.99)                            // source fading out
        #expect(opacity(into) < 0.99)                            // target fading in
    }

    @Test func morphLandsTargetAtRestAndClearsSource() {
        let (scene, story, from, into) = makeMorphStory()
        let player = StoryPlayer(story: story)
        player.scrub(globalProgress: 1.0)
        #expect(scene.entities.contains { $0 === into })
        #expect(abs(into.position.x - 2) < tolerance)             // landed exactly at its rest pose
        #expect(abs(into.position.y - 1) < tolerance)
        #expect(abs(opacity(into) - 1) < tolerance)               // fully faded in
        #expect(!scene.entities.contains { $0 === from })         // source swept by the deferred clear
    }

    @Test func morphIsScrubSafe() {
        let (scene, story, from, into) = makeMorphStory()
        let player = StoryPlayer(story: story)
        player.scrub(globalProgress: 1.0)                        // morph complete
        #expect(scene.entities.contains { $0 === into })
        #expect(!scene.entities.contains { $0 === from })
        player.scrub(globalProgress: 0.0)                        // back to the very start
        #expect(!scene.entities.contains { $0 === into })         // target detached
        #expect(scene.entities.contains { $0 === from })          // source restored…
        #expect(abs(opacity(from) - 1) < tolerance)               // …at full opacity
    }
}
