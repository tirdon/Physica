// StoryPlayer — the single writer to the timeline playhead in story mode.
//
// Story mode is fully scrub-driven: the playhead only ever moves through
// `scene.seek`, never `resume()`, so systems stay frozen and the scripted clips
// carry all motion. Scroll maps to `scrub(...)`; arrows run time tweens that
// `tick` advances frame by frame with an exact snap onto the destination beat.
// Forward navigation tweens (the camera transition plays); backward navigation
// is an instant seek (a rewind needs no show). Every move funnels through
// `apply(time:)` — the one place that seeks, dedupes, and fires the slide-change
// hook (interruptAll + drag cancel) so nothing strands mid-air.
//
// Navigation rides ONE precomputed list of `Beat`s (time + slide + step), built
// once from the story's slides. Steps move ±1 beat; slides jump between rests.
// Identity is the beat, not a float comparison, so there is a single epsilon
// (scroll-scrub dedup) and no boundary-equality dance. Two beats are dropped:
// a slide that auto-clears its content gets a rest one `boundaryNudge` *before*
// its end (so the fully-built slide shows before the clear fires at the
// boundary), and a content-entrance (`.push`) slide drops its step 0 (the
// off-board pre-slide-in state) so the slide-in plays during the arrival tween
// and the first rest is the landed slide.

import PhysicaFoundation

public struct StoryState: Sendable, Equatable {
    public var slideIndex: Int
    public var time: TimeInterval
    /// 0...1 within the current slide.
    public var slideProgress: Real
    public var isTweening: Bool
}

public enum StoryEvent: Sendable, Equatable {
    case slideChanged(from: Int, to: Int)
    case boundaryReached(slide: Int, step: Int)
    case actionTriggered(id: String)
    /// Autoplay reached the last beat and stopped (not emitted when looping).
    case autoplayFinished
}

@MainActor
public final class StoryPlayer {
    public let story: Story
    public private(set) var currentSlideIndex = 0

    private var scene: Scene { story.scene }

    /// A rest point on the timeline: the time to seek to, plus which slide/step it
    /// belongs to. Built once; navigation searches and snaps to these.
    private struct Beat: Equatable {
        let time: TimeInterval
        let slide: Int
        let step: Int
    }
    private let beats: [Beat]

    /// The "fully-built end" rest time of each slide, in order — where `nextSlide`
    /// (Down) comes to rest. A slide rests one `boundaryNudge` before its end when
    /// it auto-clears (its content still shown, about to clear) or its successor is
    /// a content entrance (whose slide-in begins exactly at the boundary); every
    /// other slide — plain clean-boundary or the last — rests at its true end.
    /// These coincide with the beats `nextStep` (Right) already stops on, so Down
    /// lands on the same fully-built ends Right does, just skipping the in-between
    /// steps — never on a bare next-slide start where the prior content has cleared.
    private let slideEndRestTimes: [TimeInterval]

    private struct Tween { let target: Beat; let forward: Bool }
    private var tween: Tween?
    private var lastSeekedTime: TimeInterval = -1

    /// Autoplay: when on, `tick` rests on each beat for `options.autoplayDwell`
    /// wall-seconds (counted down in `dwellRemaining`) then advances one beat,
    /// whose tween plays the step. Looping or stopping at the last beat is
    /// `options.autoplayLoops`. Manual nav/scroll do *not* toggle this — the shell
    /// pauses on user input if it wants; the dwell simply counts from wherever the
    /// playhead lands.
    public private(set) var isAutoplaying = false
    private var dwellRemaining: TimeInterval = 0

    /// Sole epsilon: scroll-scrub dedup and "strictly past the current beat" in
    /// nav searches, and the tween's reached-target test (the landing then snaps
    /// exactly to the stored beat time).
    private static let seekEpsilon: TimeInterval = 1e-4
    /// A deferred-clear slide's fully-built rest sits this far before its end so
    /// the auto-clear (a zero-duration clip *at* the end) is not yet reached. 10×
    /// the dedup epsilon, so the rest and the boundary are distinct beats.
    private static let boundaryNudge: TimeInterval = 1e-3

    public init(story: Story) {
        self.story = story
        self.beats = Self.buildBeats(from: story.slides)
        self.slideEndRestTimes = Self.buildSlideEndRestTimes(from: story.slides)
        scene.seek(to: 0)  // also pauses the timeline — story mode never resumes
        lastSeekedTime = 0
        currentSlideIndex = beats.first?.slide ?? 0
    }

    /// Flattens the slides into one ordered beat list. A slide's internal steps are
    /// beats as-is; its final step coincides with the next slide's start, so it is
    /// owned by the later slide (step 0) — *unless* the slide auto-clears its
    /// content, in which case a rest is kept one `boundaryNudge` before the
    /// boundary (so the slide shows fully built before it clears). The last slide
    /// keeps its true end (nothing follows to clear it).
    private static func buildBeats(from slides: [SlideRecord]) -> [Beat] {
        var beats: [Beat] = []
        for slide in slides {
            let steps = slide.stepBoundaries
            let isLastSlide = slide.index == slides.count - 1
            let nextIsEntrance = !isLastSlide && slides[slide.index + 1].entranceTransition
            for step in steps.indices {
                let isFinalStep = step == steps.count - 1
                // A content-entrance slide's step 0 is the off-board "pre-slide-in"
                // state — never a rest. The slide-in plays during the arrival tween
                // and the first rest is the landed step 1.
                if slide.entranceTransition && step == 0 { continue }
                if isFinalStep && !isLastSlide {
                    // Shared with the next slide's start. Rest one nudge before it
                    // when this slide auto-clears (show it built before the clear
                    // fires) OR the next slide is an entrance (its slide-in begins
                    // exactly here with its content off-board, so this slide's built
                    // end and that off-board t=0 are the same instant — back off so
                    // *this* slide is the rest). A clean boundary into a normal slide
                    // is owned by that slide's step-0 beat instead.
                    if slide.deferredClear || nextIsEntrance {
                        beats.append(Beat(time: steps[step] - boundaryNudge, slide: slide.index, step: step))
                    }
                } else {
                    beats.append(Beat(time: steps[step], slide: slide.index, step: step))
                }
            }
        }
        return beats
    }

    /// Fully-built end rest time per slide (see `slideEndRestTimes`). Mirrors
    /// `buildBeats`: a non-last deferred-clear slide rests `boundaryNudge` before
    /// its end; the last slide keeps its true end even if it auto-built content.
    private static func buildSlideEndRestTimes(from slides: [SlideRecord]) -> [TimeInterval] {
        let lastIndex = slides.count - 1
        return slides.map { slide in
            // Mirror `buildBeats`: rest one nudge before the end for a non-last
            // slide that auto-clears, or whose successor is a content entrance
            // (whose slide-in begins exactly at this boundary). Keep the rest and
            // the beat at the same time, else Down re-targets a beat it is already on.
            let nextIsEntrance = slide.index < lastIndex && slides[slide.index + 1].entranceTransition
            let restsBeforeEnd = (slide.deferredClear || nextIsEntrance) && slide.index != lastIndex
            return slide.endTime - (restsBeforeEnd ? boundaryNudge : 0)
        }
    }

    // MARK: Step navigation (Left / Right)

    /// Tween forward to the next beat (may roll into the next slide).
    public func nextStep() {
        let now = scene.timeline.currentTime
        guard let next = beats.first(where: { $0.time > now + Self.seekEpsilon }) else { return }
        beginTween(to: next)
    }

    /// Instant seek back to the previous beat.
    public func previousStep() {
        let now = scene.timeline.currentTime
        guard let prev = beats.last(where: { $0.time < now - Self.seekEpsilon }) else { return }
        cancelTween()
        apply(time: prev.time, force: true)
        emit(.boundaryReached(slide: prev.slide, step: prev.step))
    }

    // MARK: Slide navigation (Up / Down)

    /// Tween forward to the next slide's *fully-built end* rest — the same rest
    /// Right-stepping settles on for a slide's last step, so Down shows the slide
    /// complete (a deferred-clear slide one nudge before it clears) rather than
    /// landing on a bare next-slide start where the prior content has vanished.
    public func nextSlide() {
        let now = scene.timeline.currentTime
        guard let target = slideEndRestTimes.first(where: { $0 > now + Self.seekEpsilon }),
              let beat = beats.last(where: { $0.time <= target + Self.seekEpsilon })
        else { return }
        beginTween(to: beat)
    }

    /// Instant seek back to the start of the slide before the current one.
    public func previousSlide() {
        let target = Swift.max(0, currentSlideIndex - 1)
        guard story.slides.indices.contains(target) else { return }
        cancelTween()
        // First *restable* beat of the target — its landed state for a content-
        // entrance slide (step 0, the off-board pre-slide-in, is never a rest).
        let start = beats.first { $0.slide == target }?.time
            ?? story.slides[target].startTime
        apply(time: start, force: true)
    }

    /// Tween in one animated jump to the last slide's fully-built end (⌘+Down) —
    /// forward navigation like `nextSlide`, but straight to the final rest, so the
    /// camera transitions of every slide between here and the end play during the
    /// tween. No-op when already at (or past) the last beat.
    public func lastSlide() {
        guard let beat = beats.last else { return }
        guard beat.time > scene.timeline.currentTime + Self.seekEpsilon else { return }
        beginTween(to: beat)
    }

    /// Tween back to the first slide's landed rest — the "top" (⌘+Up). Unlike
    /// `previousSlide`'s instant step, this *animates* the rewind: the timeline
    /// reverse-plays to the first beat. No-op when already at it.
    public func firstSlide() {
        guard let beat = beats.first else { return }
        guard beat.time < scene.timeline.currentTime - Self.seekEpsilon else { return }
        beginTween(to: beat)
    }

    /// Instant seek to a slide's first rest (its start for a normal slide, its
    /// landed state for a content-entrance slide).
    public func seek(toSlide index: Int) {
        guard story.slides.indices.contains(index) else { return }
        cancelTween()
        let time = beats.first { $0.slide == index }?.time ?? story.slides[index].startTime
        apply(time: time, force: true)
    }

    // MARK: Scrubbing (scroll)

    /// Scrub by fraction of the whole timeline (0...1).
    public func scrub(globalProgress: Real) {
        cancelTween()
        let clamped = TimeInterval(Swift.min(Swift.max(globalProgress, 0), 1))
        apply(time: clamped * scene.timeline.duration)
    }

    /// Scrub within one slide by fraction of its duration (0...1).
    public func scrub(slide index: Int, progress: Real) {
        guard story.slides.indices.contains(index) else { return }
        cancelTween()
        let slide = story.slides[index]
        let p = TimeInterval(Swift.min(Swift.max(progress, 0), 1))
        apply(time: slide.startTime + p * slide.duration)
    }

    // MARK: Actions

    public func trigger(actionID: String) {
        guard let action = story.action(id: actionID) else { return }
        action.perform(scene)
        emit(.actionTriggered(id: actionID))
    }

    // MARK: Autoplay (timed playback over the beat list)

    /// Start timed playback: dwell on the current beat, then auto-advance. No-op if
    /// already playing.
    public func play() {
        guard !isAutoplaying else { return }
        isAutoplaying = true
        dwellRemaining = story.options.autoplayDwell
    }

    /// Stop timed playback. The playhead stays where it is.
    public func pause() { isAutoplaying = false }

    public func toggleAutoplay() { isAutoplaying ? pause() : play() }

    // MARK: Per-frame advance (tween + autoplay)

    /// Advances an in-flight arrow tween, or — when autoplaying and at rest — the
    /// dwell countdown that triggers the next auto-advance. No-op when neither is
    /// active, so the web RAF loop can call it unconditionally every frame.
    public func tick(deltaTime: TimeInterval) {
        guard deltaTime > 0 else { return }
        if tween != nil {
            advanceTween(deltaTime: deltaTime)
            return
        }
        guard isAutoplaying else { return }
        dwellRemaining -= deltaTime
        if dwellRemaining <= 0 { advanceAutoplay() }
    }

    private func advanceTween(deltaTime: TimeInterval) {
        guard let tween else { return }
        let now = scene.timeline.currentTime
        let stepAmount = TimeInterval(story.options.stepTweenSpeed) * deltaTime
        let next = tween.forward
            ? Swift.min(now + stepAmount, tween.target.time)
            : Swift.max(now - stepAmount, tween.target.time)
        apply(time: next)
        if abs(next - tween.target.time) < Self.seekEpsilon {
            apply(time: tween.target.time, force: true)  // exact snap onto the beat
            let landed = tween.target
            self.tween = nil
            emit(.boundaryReached(slide: landed.slide, step: landed.step))
            if isAutoplaying { dwellRemaining = story.options.autoplayDwell }
        }
    }

    /// Dwell elapsed: advance one beat (its tween then plays the step). At the last
    /// beat, loop to the first or stop, per `options.autoplayLoops`.
    private func advanceAutoplay() {
        let now = scene.timeline.currentTime
        if beats.contains(where: { $0.time > now + Self.seekEpsilon }) {
            dwellRemaining = story.options.autoplayDwell
            nextStep()
        } else if story.options.autoplayLoops, let first = beats.first {
            dwellRemaining = story.options.autoplayDwell
            apply(time: first.time, force: true)
        } else {
            isAutoplaying = false
            emit(.autoplayFinished)
        }
    }

    public var isTweening: Bool { tween != nil }

    /// The narration caption active at the current playhead time (`""` if none).
    /// The web shell renders this in its caption band each frame.
    public var currentCaption: String { story.caption(at: scene.timeline.currentTime) }

    public var state: StoryState {
        let time = scene.timeline.currentTime
        var progress: Real = 0
        if story.slides.indices.contains(currentSlideIndex) {
            let slide = story.slides[currentSlideIndex]
            if slide.duration > 0 {
                progress = Real((time - slide.startTime) / slide.duration)
            }
        }
        return StoryState(
            slideIndex: currentSlideIndex,
            time: time,
            slideProgress: Swift.min(Swift.max(progress, 0), 1),
            isTweening: tween != nil
        )
    }

    // MARK: Internals

    private func beginTween(to beat: Beat) {
        let now = scene.timeline.currentTime
        if abs(beat.time - now) < Self.seekEpsilon {
            apply(time: beat.time, force: true)
            emit(.boundaryReached(slide: beat.slide, step: beat.step))
            return
        }
        tween = Tween(target: beat, forward: beat.time > now)
    }

    private func cancelTween() { tween = nil }

    /// The one seek site: clamps, dedupes redundant seeks, then runs the
    /// slide-change hook if the slide index moved.
    ///
    /// `force` bypasses the dedup for a tween's landing snap and for instant
    /// (backward) navigation. The dedup (`seekEpsilon`) swallows sub-pixel scroll
    /// echoes; without `force` a tween that creeps within the epsilon of its
    /// target would be stranded a hair short, and the next step would re-target
    /// the same beat — sticking forever. The forced landing lands exactly on the
    /// beat, and the slide index is derived from that exact time.
    private func apply(time: TimeInterval, force: Bool = false) {
        let clamped = Swift.min(Swift.max(time, 0), scene.timeline.duration)
        guard force || abs(clamped - lastSeekedTime) >= Self.seekEpsilon else { return }
        let previous = currentSlideIndex
        scene.seek(to: clamped)
        lastSeekedTime = clamped
        let updated = slideIndex(at: clamped)
        if updated != previous {
            currentSlideIndex = updated
            scene.interactions.interruptAll(in: scene)
            scene.drag.cancelActive(in: scene)
            story.onSlideChanged?(previous, updated)
            emit(.slideChanged(from: previous, to: updated))
        }
    }

    /// Last slide whose start is at or before `time` (slides are contiguous, so the
    /// shared boundary belongs to the later slide). A deferred-clear slide's
    /// fully-built rest sits `boundaryNudge` before the boundary — well outside
    /// `seekEpsilon` — so it resolves to the earlier slide, and the boundary itself
    /// to the later one.
    private func slideIndex(at time: TimeInterval) -> Int {
        var index = 0
        for slide in story.slides where slide.startTime <= time + Self.seekEpsilon {
            index = slide.index
        }
        return index
    }

    // MARK: Events

    private var continuations: [UInt64: AsyncStream<StoryEvent>.Continuation] = [:]
    private var nextStreamID: UInt64 = 1

    public func eventStream() -> AsyncStream<StoryEvent> {
        let id = nextStreamID
        nextStreamID += 1
        return AsyncStream(bufferingPolicy: .unbounded) { continuation in
            continuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in
                    self?.continuations[id] = nil
                }
            }
        }
    }

    private func emit(_ event: StoryEvent) {
        for continuation in continuations.values {
            continuation.yield(event)
        }
    }

    public var debugString: String {
        "StoryPlayer slide \(currentSlideIndex) @ \(fmt(scene.timeline.currentTime, decimals: 2))s" + (tween != nil ? " (tweening)" : "")
    }
}
