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
// once from the story's slides. Steps move ±1 beat; slides jump between step-0
// beats. Identity is the beat, not a float comparison, so there is a single
// epsilon (scroll-scrub dedup) and no boundary-equality dance. The only nudge:
// a slide that auto-clears its content gets a rest one `boundaryNudge` *before*
// its end, so the fully-built slide shows before the clear fires at the boundary.

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

    private struct Tween { let target: Beat; let forward: Bool }
    private var tween: Tween?
    private var lastSeekedTime: TimeInterval = -1

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
    private static func buildBeats(from slides: [Slide]) -> [Beat] {
        var beats: [Beat] = []
        for slide in slides {
            let steps = slide.stepBoundaries
            let isLastSlide = slide.index == slides.count - 1
            for step in steps.indices {
                let isFinalStep = step == steps.count - 1
                if isFinalStep && !isLastSlide {
                    // Shared with the next slide's start.
                    if slide.deferredClear {
                        beats.append(Beat(time: steps[step] - boundaryNudge, slide: slide.index, step: step))
                    }
                    // else: clean boundary — the next slide's step-0 beat owns this time.
                } else {
                    beats.append(Beat(time: steps[step], slide: slide.index, step: step))
                }
            }
        }
        return beats
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

    /// Tween forward to the next slide's start (its step-0 beat); on the last
    /// slide, tween to the final beat.
    public func nextSlide() {
        let now = scene.timeline.currentTime
        if let next = beats.first(where: { $0.step == 0 && $0.time > now + Self.seekEpsilon }) {
            beginTween(to: next)
        } else if let last = beats.last, last.time > now + Self.seekEpsilon {
            beginTween(to: last)
        }
    }

    /// Instant seek back to the start of the slide before the current one.
    public func previousSlide() {
        let target = Swift.max(0, currentSlideIndex - 1)
        guard story.slides.indices.contains(target) else { return }
        cancelTween()
        let start = beats.first { $0.slide == target && $0.step == 0 }?.time
            ?? story.slides[target].startTime
        apply(time: start, force: true)
    }

    /// Instant seek to a slide's start.
    public func jump(toSlide index: Int) {
        guard story.slides.indices.contains(index) else { return }
        cancelTween()
        apply(time: story.slides[index].startTime, force: true)
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

    // MARK: Per-frame tween advance

    /// Advances an in-flight arrow tween. No-op when nothing is tweening, so the
    /// web RAF loop can call it unconditionally.
    public func tick(deltaTime: TimeInterval) {
        guard let tween, deltaTime > 0 else { return }
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
        }
    }

    public var isTweening: Bool { tween != nil }

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
            continuation.onTermination = { _ in
                Task { @MainActor [weak self] in
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
