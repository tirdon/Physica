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

    // Story content persists by default (a slide takes things off the board with
    // `s.clear`/`s.clearAll`). We track two things for those: the globals
    // (`scene.add`ed before/between slides) that `clearAll()` must keep, and each
    // slide's own new entities so the next slide's `addLastState()` can re-pull
    // them after a clear.
    private var globalIDs: Set<ObjectIdentifier> = []
    private var accountedClips = 0
    private var lastIntroducedOwn: [Entity] = []

    /// Invoked by the `StoryPlayer`'s slide-change hook (with from/to indices)
    /// whenever the current slide changes. Use it to reset transient,
    /// interaction-introduced state that should not persist when the viewer
    /// navigates away and back (those entities are outside the scrub history,
    /// so a seek never clears them).
    public var onSlideChanged: (@MainActor (_ from: Int, _ to: Int) -> Void)?

    public init(scene: Scene, options: StoryOptions = StoryOptions()) {
        self.scene = scene
        self.options = options
    }

    /// Records a slide. Content **persists by default**; a slide clears the board
    /// itself with `s.clearAll()` (keeps the globals) or `s.clear(x)` (specific),
    /// and re-pulls the previous slide's new content with `s.addLastState()` after
    /// a clear. Globals are anything `scene.add`ed *before* the slides.
    ///
    /// Mechanics: snapshots `timeline.duration` / clip count around `content`,
    /// derives the slide's range and step boundaries, and records the slide's own
    /// new entities (for the next `addLastState`) and the running global set (for
    /// `clearAll`). The content must enqueue at least one clip.
    @discardableResult
    public func slide(_ title: String, _ content: (Scene) -> Void) -> Slide {
        // Anything enqueued since the last slide (globals `scene.add`ed before or
        // between slides) is recorded as global, so `clearAll()` keeps it.
        absorbGlobals()
        scene.storyGlobalIDs = globalIDs
        // Fire the *previous* slide's deferred clearAll() now (at this slide's
        // start) — before this slide's content, so a clearAll()+addLastState()
        // pair reads as clear-then-re-add across the boundary.
        scene.flushPendingClearAll()

        let startTime = scene.timeline.duration
        let startClip = scene.timeline.clips.count
        scene.beginSlideCarry(previous: lastIntroducedOwn)
        content(scene)
        let endClip = scene.timeline.clips.count
        // A slide may be timeline-empty when it only inherits globals and defers a
        // clearAll (e.g. a degraded no-font slide); that pending clear counts as
        // intent, so only an inert slide that did nothing at all trips this.
        precondition(endClip > startClip || scene.clearAllPending,
                     "Story slide '\(title)' enqueued no clips")
        let endTime = scene.timeline.duration

        // This slide's *own* new (non-global) entities — excluding what it pulled in
        // via `addLastState` — seed the next slide's `addLastState`, so carry-over is
        // one step, not transitive.
        let introduced = introducedEntities(in: startClip..<endClip)
        let carriedIn = Set(scene.carriedThisSlide.map(ObjectIdentifier.init))
        lastIntroducedOwn = introduced.filter {
            !globalIDs.contains(ObjectIdentifier($0)) && !carriedIn.contains(ObjectIdentifier($0))
        }
        accountedClips = scene.timeline.clips.count

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

    /// Records every entity introduced by clips not yet attributed to a slide
    /// (the `scene.add` calls made before/between slides) as global.
    private func absorbGlobals() {
        let end = scene.timeline.clips.count
        guard accountedClips < end else { return }
        for entity in introducedEntities(in: accountedClips..<end) {
            globalIDs.insert(ObjectIdentifier(entity))
        }
        accountedClips = end
    }

    /// Deduped entities introduced (via any `AddEntitiesTrack`) by the clips in
    /// `range` — the build-time view of what those clips put on screen.
    private func introducedEntities(in range: Range<Int>) -> [Entity] {
        var result: [Entity] = []
        var seen = Set<ObjectIdentifier>()
        for index in range {
            for track in scene.timeline.clips[index].tracks {
                guard let add = track as? AddEntitiesTrack else { continue }
                for entity in add.introducedTargets where seen.insert(ObjectIdentifier(entity)).inserted {
                    result.append(entity)
                }
            }
        }
        return result
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
