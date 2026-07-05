// Timeline — append-only clip history with deterministic playback and scrubbing.
//
// `advance` plays clips in order, finishing zero-duration clips without consuming
// time. `seek` fast-forwards by applying intermediate clips at their end and
// rewinds by undoing clips in reverse — the scrub-safety contract of the tracks.

import PhysicaMath
import PhysicaGeometry
import PhysicaTypesetting

public enum TimelineEvent: Sendable, Equatable {
    case clipStarted(index: Int, label: String)
    case clipFinished(index: Int)
    case seeked(to: TimeInterval)
    case paused
    case resumed
    case finished
}

/// Sendable snapshot for playback UI.
public struct TimelineState: Sendable, Equatable {
    public var currentTime: TimeInterval
    public var duration: TimeInterval
    public var isPaused: Bool
    public var isFinished: Bool
}

@MainActor
public final class Timeline {
    public private(set) var clips: [AnimationClip] = []
    public private(set) var currentTime: TimeInterval = 0
    public private(set) var isPaused = false

    /// Index of the clip currently playing (== clips.count when the script is done).
    private var activeIndex = 0
    private var didEmitFinished = false
    private var isSeeking = false

    /// Cumulative clip start times and the running total, maintained by
    /// `enqueue` (a clip's duration is fixed once enqueued). Playback and
    /// story scrubbing read start/duration every frame, so neither may be an
    /// O(clips) scan.
    private var clipStarts: [TimeInterval] = []
    private var cachedDuration: TimeInterval = 0

    public var duration: TimeInterval { cachedDuration }

    public var isFinished: Bool { activeIndex >= clips.count }

    public var state: TimelineState {
        TimelineState(
            currentTime: currentTime,
            duration: duration,
            isPaused: isPaused,
            isFinished: isFinished
        )
    }

    public init() {}

    // MARK: Scheduling

    package func enqueue(_ clip: AnimationClip) {
        clipStarts.append(cachedDuration)
        cachedDuration += clip.duration
        clips.append(clip)
        didEmitFinished = false
    }

    // MARK: Playback

    public func setPaused(_ paused: Bool) {
        guard paused != isPaused else { return }
        isPaused = paused
        emit(paused ? .paused : .resumed)
    }

    func advance(by deltaTime: TimeInterval, in scene: Scene) {
        guard !isPaused, deltaTime > 0 else { return }
        var remaining = deltaTime

        while activeIndex < clips.count {
            let clip = clips[activeIndex]
            let clipStart = startTime(of: activeIndex)
            if !clip.hasBegun {
                clip.begin(in: scene)
                emit(.clipStarted(index: activeIndex, label: clip.label))
            }
            let localTime = currentTime - clipStart
            let timeToEnd = clip.duration - localTime

            if remaining >= timeToEnd {
                clip.apply(at: clip.duration, in: scene)
                currentTime = clipStart + clip.duration
                remaining -= max(timeToEnd, 0)
                emit(.clipFinished(index: activeIndex))
                activeIndex += 1
            } else {
                currentTime += remaining
                clip.apply(at: currentTime - clipStart, in: scene)
                remaining = 0
                break
            }
        }

        if activeIndex >= clips.count, !clips.isEmpty, !didEmitFinished {
            didEmitFinished = true
            emit(.finished)
        }
    }

    // MARK: Seek

    func seek(to time: TimeInterval, in scene: Scene) {
        guard !clips.isEmpty else { return }
        isSeeking = true
        defer { isSeeking = false }

        let target = min(max(time, 0), duration)
        let (targetIndex, localTime) = locate(target)

        // Fast-forward: finish every clip before the target.
        while activeIndex < targetIndex {
            let clip = clips[activeIndex]
            clip.begin(in: scene)
            clip.apply(at: clip.duration, in: scene)
            activeIndex += 1
        }

        // Rewind: undo clips we had entered beyond the target, newest first.
        while activeIndex > targetIndex {
            if activeIndex < clips.count {
                clips[activeIndex].rewind(in: scene)
            }
            activeIndex -= 1
        }

        let clip = clips[targetIndex]
        clip.begin(in: scene)
        clip.apply(at: localTime, in: scene)
        currentTime = target
        didEmitFinished = false
        emit(.seeked(to: target))
    }

    /// Clip index containing `time` (last clip whose start ≤ time) and the local
    /// offset — binary search over the cached starts (zero-duration clips share a
    /// start; taking the *last* one matches playback order).
    private func locate(_ time: TimeInterval) -> (index: Int, localTime: TimeInterval) {
        guard !clips.isEmpty else { return (0, 0) }
        var low = 0
        var high = clipStarts.count
        while low < high {
            let mid = (low + high) / 2
            if clipStarts[mid] <= time { low = mid + 1 } else { high = mid }
        }
        let index = Swift.max(low - 1, 0)
        return (index, min(max(time - clipStarts[index], 0), clips[index].duration))
    }

    private func startTime(of index: Int) -> TimeInterval {
        index < clipStarts.count ? clipStarts[index] : cachedDuration
    }

    // MARK: Events

    private var continuations: [UInt64: AsyncStream<TimelineEvent>.Continuation] = [:]
    private var nextStreamID: UInt64 = 1

    /// Buffered event stream; safe to subscribe before driving the timeline.
    public func eventStream() -> AsyncStream<TimelineEvent> {
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

    private func emit(_ event: TimelineEvent) {
        if isSeeking, case .clipStarted = event { return }
        if isSeeking, case .clipFinished = event { return }
        for continuation in continuations.values {
            continuation.yield(event)
        }
    }

    public var debugString: String {
        var lines: [String] = ["timeline \(fmt(currentTime, decimals: 2))/\(fmt(duration, decimals: 2))s clips(\(clips.count)):"]
        var start: TimeInterval = 0
        for clip in clips {
            lines.append("  @\(fmt(start, decimals: 2))s \(clip.label) (\(fmt(clip.duration, decimals: 2))s)")
            start += clip.duration
        }
        return lines.joined(separator: "\n")
    }
}
