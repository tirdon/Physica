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
import PhysicaFoundation

public struct SlideRecord: Sendable, Equatable {
    public let index: Int
    public let title: String
    public let startTime: TimeInterval
    public let endTime: TimeInterval
    public let stepBoundaries: [TimeInterval]
    /// Whether advancing past this slide's end fires an auto-clear of its content.
    /// The player rests one beat *before* the boundary so the fully-built slide is
    /// shown before it clears (otherwise seeking to the boundary fast-forwards the
    /// clear and the last step would render the content already gone).
    let deferredClear: Bool
    /// Whether this slide opens with a content-entrance transition (`.push`): its
    /// content slides in over the previous board. Its step 0 is the off-board
    /// "pre-slide-in" state, so the player skips it as a rest — the slide-in plays
    /// during the arrival tween and the first rest is the landed step 1.
    let entranceTransition: Bool

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
    /// Autoplay dwell: wall-seconds the player rests on a beat before advancing to
    /// the next (the step's own animation plays during the tween, then it dwells).
    public var autoplayDwell: TimeInterval
    /// Whether autoplay restarts from the first beat after the last, instead of
    /// stopping (kiosk / looping-explainer mode).
    public var autoplayLoops: Bool

    public init(
        pixelsPerSecond: Real = 480,
        minimumSlidePixels: Real = 400,
        stepTweenSpeed: Real = 2,
        autoplayDwell: TimeInterval = 2,
        autoplayLoops: Bool = false
    ) {
        self.pixelsPerSecond = pixelsPerSecond
        self.minimumSlidePixels = minimumSlidePixels
        self.stepTweenSpeed = stepTweenSpeed
        self.autoplayDwell = autoplayDwell
        self.autoplayLoops = autoplayLoops
    }
}

@MainActor
public final class Story {
    public let scene: Scene
    public var options: StoryOptions
    public private(set) var slides: [SlideRecord] = []
    private var actions: [StoryAction] = []

    // Story content is **slide-scoped by default**: each slide's own-introduced
    // entities auto-clear when the viewer advances to the next slide. We hold the
    // *previous* slide's computed clear set here and flush it at the next slide's
    // start (deferred, so the slide stays visible through its own duration; the
    // last slide's set is never flushed, so its board persists). Globals
    // (`scene.add`ed before/between slides) are never in a slide's own set, so
    // they persist untracked; `s.carry(_:)` opts specific content out of the clear.
    private var pendingAutoClear: [Entity] = []

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

    /// The scene background, surfaced on the story so authors set it without
    /// reaching into `story.scene` (`story.background = .blackboard`).
    public var background: SceneBackground {
        get { scene.background }
        set { scene.background = newValue }
    }

    /// Adds global scaffolding to the board (forwards to `scene.add`). Call this
    /// *before/between* slides for content that should persist across the whole
    /// story — globals are never part of any slide's own auto-clear set. Inside a
    /// slide closure use the `s.add(...)` you're given instead (slide-scoped).
    @discardableResult
    public func add(_ items: any Animatable...) -> Animation {
        scene.addItems(items)
    }

    /// Records a slide. Content is **slide-scoped by default**: the entities this
    /// slide introduces auto-clear when the viewer advances to the next slide.
    /// Opt specific content out with `s.carry(x)` (persists onward) or take things
    /// off mid-slide with `s.clear(x)`. Globals — anything `scene.add`ed *before*
    /// the slides — persist for the whole story (never in a slide's own set). The
    /// last slide never auto-clears, so its final board stays.
    ///
    /// Mechanics: snapshots `timeline.duration` / clip count around `content`,
    /// derives the slide's range and step boundaries, and records its own-introduced
    /// set (minus `carry`/in-slide removals) as the deferred auto-clear, flushed at
    /// the next slide's start. The content must enqueue at least one clip.
    ///
    /// A `transition: .push(from:)` makes the slide a **content entrance**: its
    /// introduced content slides in over the previous board (the previous slide's
    /// clear is deferred until the slide-in finishes, so it shows through behind).
    @discardableResult
    public func slide(
        _ title: String,
        transition: SlideTransition = .none,
        exit: ExitTransition = .clear,
        _ content: (Scene) -> Void
    ) -> SlideRecord {
        let isEntrance = transition.isContentEntrance

        // The *previous* slide's deferred auto-clear. A normal slide fires it now,
        // at this slide's start (the old board drops as the viewer crosses in). A
        // content entrance (`.push`) fires it *after* its slide-in instead, so the
        // previous board stays visible underneath while the new content slides over.
        let previousClear = pendingAutoClear
        pendingAutoClear = []
        if !isEntrance {
            scene.enqueueSlideClear(previousClear)
        }

        let startTime = scene.timeline.duration
        let startClip = scene.timeline.clips.count
        // The slide's first caption anchors here (covering any arrival transition),
        // even though the transition/content clips below advance the live time.
        pendingCaptionStart = startTime

        // Content-agnostic transitions (fade/zoom) are the slide's first clip,
        // ahead of the content. A content-arrival transition (`.push`/`.morph`) is
        // built *after* the content (it needs the introduced set, and morph the
        // previous set too) but enqueued here so it plays first; its `introduced`/
        // `sources` are filled in below and the previous clear follows it.
        var arrival: (any ContentArrivalTrack)?
        if isEntrance {
            let track = transition.makeArrivalTrack()
            arrival = track
            scene.timeline.enqueue(AnimationClip(label: track.label, tracks: [track]))
            scene.enqueueSlideClear(previousClear)
        } else {
            transition.enqueue(on: scene)
        }

        // The content closure's own clips begin here, so `introduced`/`removed`
        // scan only those — the injected slide-in/clear are excluded.
        let contentStartClip = scene.timeline.clips.count
        content(scene)
        let contentEndClip = scene.timeline.clips.count

        // The slide's own-introduced set — needed both for the exit effect and
        // the auto-clear bookkeeping below.
        let scanStart = isEntrance ? contentStartClip : startClip
        let introduced = introducedEntities(in: scanStart..<contentEndClip)

        // A non-`.clear` exit animates the introduced content away as the
        // slide's final beat; the boundary clear then drops the (now invisible)
        // entities as usual, so scrubbing back restores both.
        if !introduced.isEmpty, let exitAnimations = exit.animations(for: introduced) {
            _ = scene.playItems(exitAnimations, for: exit.duration, easing: nil)
        }

        let endClip = scene.timeline.clips.count
        // An empty slide is allowed: a zero-duration rest on the globals already on
        // the board (e.g. a degraded no-font slide that shows only the scaffolding).
        let endTime = scene.timeline.duration

        // This slide's auto-clear set: entities it introduced, minus the ones it
        // `carry`-ed forward and any it already removed within the slide (a `.fade`
        // overlay or `.highlight` border, introduced *and* removed in one clip).
        // Globals (added before/between slides) aren't in `introduced`.
        let carried = Set(scene.carriedThisSlide.map(ObjectIdentifier.init))
        let removedInSlide = removedEntities(in: scanStart..<endClip)
        pendingAutoClear = introduced.filter {
            let id = ObjectIdentifier($0)
            return !carried.contains(id) && !removedInSlide.contains(id)
        }
        // Hand the arrival track its content: `introduced` (carried in / morph
        // targets) and, for morph, `previousClear` as the morph sources. It adds
        // the targets itself so they show mid-arrival, ahead of the content's own
        // 0-duration adds.
        arrival?.introduced = introduced
        arrival?.sources = previousClear
        scene.resetSlideCarry()

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

        let slide = SlideRecord(
            index: slides.count, title: title,
            startTime: startTime, endTime: endTime,
            stepBoundaries: boundaries, deferredClear: !pendingAutoClear.isEmpty,
            entranceTransition: isEntrance
        )
        slides.append(slide)
        pendingCaptionStart = nil  // a between-slides caption stamps at the live time
        return slide
    }

    /// Entities removed (via any `RemoveEntityTrack`) by the clips in `range` —
    /// the build-time view of what those clips take off screen. Used to subtract
    /// net-transient entities from the slide's carry-forward set.
    private func removedEntities(in range: Range<Int>) -> Set<ObjectIdentifier> {
        var result = Set<ObjectIdentifier>()
        for index in range {
            for track in scene.timeline.clips[index].tracks {
                guard let remove = track as? RemoveEntityTrack else { continue }
                result.insert(ObjectIdentifier(remove.removedTarget))
            }
        }
        return result
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

    // Narration captions: a fixed subtitle band synced to the steps, decoupled
    // from in-scene text. Each is time-stamped at the moment it is recorded during
    // slide building; the one active at a time t is the last recorded at or before
    // t (so it persists until the next). The web shell renders the active caption;
    // it doubles as the script when autoplaying.
    private var captionEntries: [(time: TimeInterval, text: String)] = []
    /// The current slide's start time, pending until its first caption claims it.
    /// A slide's *opening* caption anchors to the slide start (so it covers an
    /// arrival transition — `.push`/`.fade`/`.zoom` — whose clip would otherwise
    /// delay the stamp); later captions in the slide stamp at the live time.
    private var pendingCaptionStart: TimeInterval?

    /// Records a narration caption starting *now* (the current timeline position),
    /// active until the next caption. Call inside a slide closure interleaved with
    /// content — `story.caption("Resolve the forces"); s.play(.draw(weight))` — and
    /// pass `""` to blank the band. A slide's first caption anchors to the slide's
    /// start, so it shows through an entrance transition rather than after it.
    public func caption(_ text: String) {
        let time = pendingCaptionStart ?? scene.timeline.duration
        pendingCaptionStart = nil
        captionEntries.append((time: time, text: text))
    }

    /// The narration caption active at `time` (`""` when none has been recorded yet).
    public func caption(at time: TimeInterval) -> String {
        var result = ""
        for entry in captionEntries where entry.time <= time + 1e-6 { result = entry.text }
        return result
    }

    func action(id: String) -> StoryAction? {
        actions.first { $0.id == id }
    }

    /// Total scrollable height (web layout): the per-slide spacer heights summed.
    public var totalScrollPixels: Real {
        slides.reduce(0) { $0 + slideScrollPixels($1) }
    }

    /// Scroll-spacer height for one slide.
    public func slideScrollPixels(_ slide: SlideRecord) -> Real {
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
