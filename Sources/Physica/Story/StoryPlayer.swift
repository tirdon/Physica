// StoryPlayer — the single writer to the timeline playhead in story mode.
//
// Story mode is fully scrub-driven: the playhead only ever moves through
// `scene.seek`, never `resume()`, so systems stay frozen and the scripted clips
// carry all motion. Scroll maps to `scrub(...)`; arrows run time tweens that
// `tick` advances frame by frame with an exact snap onto the destination
// boundary. Forward navigation tweens (the camera transition plays); backward
// navigation is an instant seek (a rewind needs no show). Every move funnels
// through `apply(time:)` — the one place that seeks, dedupes, and fires the
// slide-change hook (interruptAll + drag cancel) so nothing strands mid-air.

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
    private struct Tween { let target: TimeInterval; let forward: Bool }
    private var tween: Tween?
    private var lastSeekedTime: TimeInterval = -1

    private static let boundaryEpsilon: TimeInterval = 1e-6
    private static let seekEpsilon: TimeInterval = 1e-4

    public init(story: Story) {
        self.story = story
        scene.seek(to: 0)  // also pauses the timeline — story mode never resumes
        lastSeekedTime = 0
        currentSlideIndex = story.slides.isEmpty ? 0 : slideIndex(at: 0)
    }

    // MARK: Step navigation (Left / Right)

    /// Tween forward to the next step boundary (may roll into the next slide).
    public func nextStep() {
        guard let next = boundaries.first(where: { $0 > scene.timeline.currentTime + Self.boundaryEpsilon }) else { return }
        beginTween(to: next)
    }

    /// Instant seek back to the previous step boundary.
    public func previousStep() {
        guard let prev = boundaries.last(where: { $0 < scene.timeline.currentTime - Self.boundaryEpsilon }) else { return }
        cancelTween()
        apply(time: prev)
        emitBoundary(at: prev)
    }

    // MARK: Slide navigation (Up / Down)

    /// Tween forward into the next slide, far enough to play its opening clip
    /// (the camera transition), then rest on its first internal boundary.
    public func nextSlide() {
        let target = currentSlideIndex + 1
        guard target < story.slides.count else { return }
        let slide = story.slides[target]
        let landing = slide.stepBoundaries.count > 1 ? slide.stepBoundaries[1] : slide.endTime
        beginTween(to: landing)
    }

    /// Instant seek back to the previous slide's start.
    public func previousSlide() {
        let target = currentSlideIndex - 1
        guard target >= 0 else { return }
        cancelTween()
        apply(time: story.slides[target].startTime)
    }

    /// Instant seek to a slide's start.
    public func jump(toSlide index: Int) {
        guard index >= 0, index < story.slides.count else { return }
        cancelTween()
        apply(time: story.slides[index].startTime)
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
        guard index >= 0, index < story.slides.count else { return }
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
            ? Swift.min(now + stepAmount, tween.target)
            : Swift.max(now - stepAmount, tween.target)
        apply(time: next)
        if abs(next - tween.target) < Self.boundaryEpsilon {
            apply(time: tween.target)  // exact snap onto the boundary
            self.tween = nil
            emitBoundary(at: tween.target)
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

    private func beginTween(to target: TimeInterval) {
        let now = scene.timeline.currentTime
        if abs(target - now) < Self.boundaryEpsilon {
            apply(time: target)
            emitBoundary(at: target)
            return
        }
        tween = Tween(target: target, forward: target > now)
    }

    private func cancelTween() { tween = nil }

    /// The one seek site: clamps, dedupes redundant seeks, then runs the
    /// slide-change hook if the slide index moved.
    private func apply(time: TimeInterval) {
        let clamped = Swift.min(Swift.max(time, 0), scene.timeline.duration)
        guard abs(clamped - lastSeekedTime) >= Self.seekEpsilon else { return }
        let previous = currentSlideIndex
        scene.seek(to: clamped)
        lastSeekedTime = clamped
        let updated = slideIndex(at: clamped)
        if updated != previous {
            currentSlideIndex = updated
            scene.interactions.interruptAll(in: scene)
            scene.drag.cancelActive(in: scene)
            emit(.slideChanged(from: previous, to: updated))
        }
    }

    /// Last slide whose start is at or before `time` (slides are contiguous, so
    /// the shared boundary belongs to the later slide).
    private func slideIndex(at time: TimeInterval) -> Int {
        var index = 0
        for slide in story.slides where slide.startTime <= time + Self.boundaryEpsilon {
            index = slide.index
        }
        return index
    }

    /// All distinct step boundaries across the timeline, in order. Slides are
    /// contiguous (slide i's end == slide i+1's start), so adjacent-dedup of the
    /// concatenation is already sorted and unique.
    private var boundaries: [TimeInterval] {
        var times: [TimeInterval] = []
        for slide in story.slides {
            for boundary in slide.stepBoundaries {
                if let last = times.last, abs(last - boundary) <= Self.boundaryEpsilon { continue }
                times.append(boundary)
            }
        }
        return times
    }

    private func emitBoundary(at time: TimeInterval) {
        let slide = slideIndex(at: time)
        guard story.slides.indices.contains(slide) else { return }
        let steps = story.slides[slide].stepBoundaries
        if let step = steps.firstIndex(where: { abs($0 - time) < Self.seekEpsilon }) {
            emit(.boundaryReached(slide: slide, step: step))
        }
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
