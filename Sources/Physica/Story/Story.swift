// Story — a slideshow view over a single scrubbable timeline.
//
// "Animation mode" is one timeline you scrub end to end. Story mode partitions
// that same timeline into slides (Up/Down navigate them) whose internal clips
// are steps (Left/Right navigate those), and registers named action buttons
// that animate in parallel via the interaction layer. Nothing here drives the
// clock — `StoryPlayer` does — so a Story is just the recorded structure:
// per-slide time ranges and step boundaries computed from `timeline.duration`
// snapshots taken around each slide's content.

/// One section of the story: a contiguous timeline range plus the step
/// boundaries (absolute times) the playhead rests on within it. `stepBoundaries`
/// always begins with `startTime` and ends with `endTime` (when the slide has
/// any duration); zero-duration clips collapse into the surrounding boundary.
public struct Slide: Sendable, Equatable {
    public let index: Int
    public let title: String
    public let startTime: TimeInterval
    public let endTime: TimeInterval
    public let stepBoundaries: [TimeInterval]

    public var duration: TimeInterval { endTime - startTime }
    /// Number of rests in this slide (1 = a single instantaneous slide).
    public var stepCount: Int { stepBoundaries.count }
}

/// A named, replayable action bound to a story. Holds a `@MainActor` closure, so
/// it is intentionally not Sendable.
struct StoryAction {
    let id: String
    let label: String
    let perform: @MainActor (Scene) -> Void
}

/// Tuning shared by the player and the web shell.
public struct StoryOptions: Sendable {
    /// Scroll-spacer height per timeline second (web layout).
    public var pixelsPerSecond: Real
    /// Floor on a slide's scroll-spacer height, so instantaneous slides still
    /// occupy a scrollable band.
    public var minimumSlidePixels: Real
    /// Tween rate for `nextStep`/`nextSlide`, in timeline-seconds per wall-second.
    public var stepTweenSpeed: Real

    public init(
        pixelsPerSecond: Real = 480,
        minimumSlidePixels: Real = 400,
        stepTweenSpeed: Real = 2
    ) {
        self.pixelsPerSecond = pixelsPerSecond
        self.minimumSlidePixels = minimumSlidePixels
        self.stepTweenSpeed = stepTweenSpeed
    }
}

@MainActor
public final class Story {
    public let scene: Scene
    public var options: StoryOptions
    public private(set) var slides: [Slide] = []
    private var actions: [StoryAction] = []

    public init(scene: Scene, options: StoryOptions = StoryOptions()) {
        self.scene = scene
        self.options = options
    }

    /// Records a slide: snapshots `timeline.duration` before and after running
    /// `content` (which scripts clips on the scene), then derives the slide's
    /// range and step boundaries. The content must enqueue at least one clip.
    @discardableResult
    public func slide(_ title: String, _ content: (Scene) -> Void) -> Slide {
        let startTime = scene.timeline.duration
        let startClip = scene.timeline.clips.count
        content(scene)
        let endClip = scene.timeline.clips.count
        precondition(endClip > startClip, "Story slide '\(title)' enqueued no clips")
        let endTime = scene.timeline.duration

        var boundaries: [TimeInterval] = [startTime]
        var cursor = startTime
        for index in startClip..<endClip {
            cursor += scene.timeline.clips[index].duration
            // Zero-duration clips (an `add`) don't advance the cursor, so they
            // collapse into the previous boundary instead of duplicating it.
            if cursor - (boundaries.last ?? startTime) > 1e-6 {
                boundaries.append(cursor)
            }
        }

        let slide = Slide(
            index: slides.count, title: title,
            startTime: startTime, endTime: endTime, stepBoundaries: boundaries
        )
        slides.append(slide)
        return slide
    }

    /// Registers a triggerable action. `id` defaults to `label`; later
    /// registrations with the same id replace the earlier one.
    public func action(_ label: String, id: String? = nil, _ perform: @escaping @MainActor (Scene) -> Void) {
        let actionID = id ?? label
        let entry = StoryAction(id: actionID, label: label, perform: perform)
        if let existing = actions.firstIndex(where: { $0.id == actionID }) {
            actions[existing] = entry
        } else {
            actions.append(entry)
        }
    }

    /// Buttons for the web shell, in registration order.
    public var actionList: [(id: String, label: String)] {
        actions.map { ($0.id, $0.label) }
    }

    func action(id: String) -> StoryAction? {
        actions.first { $0.id == id }
    }

    /// Total scrollable height (web layout): the per-slide spacer heights summed.
    public var totalScrollPixels: Real {
        slides.reduce(0) { $0 + slideScrollPixels($1) }
    }

    /// Scroll-spacer height for one slide.
    public func slideScrollPixels(_ slide: Slide) -> Real {
        Swift.max(options.minimumSlidePixels, options.pixelsPerSecond * Real(slide.duration))
    }

    public var debugString: String {
        var lines = ["Story '\(scene.name)' slides(\(slides.count)):"]
        for slide in slides {
            let bounds = slide.stepBoundaries.map { fmt($0, decimals: 2) }.joined(separator: ", ")
            lines.append("  [\(slide.index)] '\(slide.title)' \(fmt(slide.startTime, decimals: 2))–\(fmt(slide.endTime, decimals: 2))s steps[\(bounds)]")
        }
        if !actions.isEmpty {
            lines.append("  actions: " + actions.map { $0.id }.joined(separator: ", "))
        }
        return lines.joined(separator: "\n")
    }
}
