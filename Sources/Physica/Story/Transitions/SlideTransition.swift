// SlideTransition — the entrance effect played as a viewer arrives at a story
// slide: `story.slide("Solve", transition: .push(from: .right)) { … }`. Two
// families:
//
//   • Content-agnostic (`.fade`, `.zoom`) — a camera move or a transient
//     fullscreen overlay enqueued as the slide's **first clip** (step 0). It
//     plays on arrival and never needs to know what the slide adds.
//   • Content entrance (`.push`, `.morph`) — animates the slide's *own*
//     introduced content in (a card sliding over the board, or a
//     TransformMatching morph from the previous slide). These ARE
//     content-aware, so `Story.slide` drives them: it runs the slide's content
//     first, then hands the introduced entities to the arrival track it
//     enqueued up front (and defers the previous slide's clear to *after* the
//     arrival, so the old board shows through underneath).
//
// Every kind is scrub-safe — the fade introduces/removes its own quad in one
// clip (like `.highlight`), the camera moves ride the `SceneCamera` proxy, and
// the push/morph lerp state they capture at clip begin. One file per family in
// this directory; the shared `ContentArrivalTrack` seam lives below.

import PhysicaMath
import PhysicaGeometry
import PhysicaKernel

@MainActor
public struct SlideTransition: Sendable {
    enum Kind: Sendable {
        case none
        case fade(Color?)
        case push(Unit)
        case zoom(Real)
        case morph
    }

    let kind: Kind
    let duration: Duration

    /// No transition — the slide's content carries its own reveal (the default).
    public static var none: SlideTransition {
        SlideTransition(kind: .none, duration: .zero)
    }

    /// Fade up from `color` (defaults to the scene background) over `duration`.
    public static func fade(_ color: Color? = nil, duration: Duration = .seconds(0.7)) -> SlideTransition {
        SlideTransition(kind: .fade(color), duration: duration)
    }

    /// The slide's own content slides in from `edge` as a layer over the previous
    /// slide: the introduced entities start one frame toward `edge` (off-board)
    /// and ease to their resting layout as a rigid group, so the previous slide
    /// shows through behind them. Reads best when the previous board is still
    /// present — `Story.slide` keeps it underneath until the slide-in finishes.
    public static func push(from edge: Unit, duration: Duration = .seconds(0.8)) -> SlideTransition {
        SlideTransition(kind: .push(edge), duration: duration)
    }

    /// Push in/out: the camera starts at zoom `extent` and eases to the slide's
    /// resting zoom (larger extent = starts further out).
    public static func zoom(from extent: Real, duration: Duration = .seconds(0.8)) -> SlideTransition {
        SlideTransition(kind: .zoom(extent), duration: duration)
    }

    /// Morphs matching content across the boundary (TransformMatching-style): each
    /// previous-slide entity is paired with this slide's by `name`, and every pair
    /// tweens from the old pose to the new — position/scale always, plus path
    /// geometry when both ends are shape (`PathEntity`) — while crossfading. The
    /// previous slide stays visible as the morph source and clears once it lands;
    /// unmatched new content reveals through this slide's own later steps. Match by
    /// giving the two entities the same non-empty `name`.
    public static func morph(duration: Duration = .seconds(0.8)) -> SlideTransition {
        SlideTransition(kind: .morph, duration: duration)
    }

    /// True for transitions that animate the slide's *own* content on arrival
    /// (`.push`, `.morph`). `Story.slide` special-cases these: it builds the
    /// arrival clip *after* the content closure runs (once it knows which entities
    /// the slide introduced — and, for morph, which the previous slide left) rather
    /// than the content-agnostic up-front `enqueue(on:)` path, and defers the
    /// previous slide's clear until after the arrival plays.
    var isContentEntrance: Bool {
        switch kind {
        case .push, .morph: return true
        default: return false
        }
    }

    /// Builds the (initially empty) content-arrival track for a `.push` / `.morph`.
    /// `Story.slide` enqueues it as the slide's first clip, runs the content, then
    /// fills its `introduced` (this slide's content) and `sources` (the previous
    /// slide's, which `.morph` matches against). Precondition: `isContentEntrance`.
    func makeArrivalTrack() -> any ContentArrivalTrack {
        switch kind {
        case .push(let edge):
            return ContentPushTrack(
                edge: edge, duration: duration.interval, easing: .smooth,
                label: "transition.push(from: .\(edge))"
            )
        case .morph:
            return MorphTransitionTrack(
                duration: duration.interval, easing: .smooth, label: "transition.morph()"
            )
        default:  // not reached for non-entrance kinds
            return ContentPushTrack(edge: .right, duration: 0, easing: .smooth, label: "transition.push()")
        }
    }

    /// Enqueues a content-agnostic transition clip on `scene` (no-op for `.none`
    /// and for `.push`, which `Story.slide` drives instead). Called by
    /// `Story.slide` right before the slide's content runs.
    func enqueue(on scene: Scene) {
        switch kind {
        case .none, .push, .morph:
            return  // `.push`/`.morph` are content-aware (Story-driven); `.none` is nothing.
        case .fade(let color):
            let overlay = PathEntity()
            overlay.name = "transition"
            overlay.components[RenderStyleComponent.self] = RenderStyleComponent(
                color: color ?? scene.background.baseColor,
                strokeColor: nil, strokeWidth: 0, isFilled: true, opacity: 1
            )
            let animation = Animation(pairs: [
                AnimationPair(target: overlay, blueprint: FadeTransitionBlueprint())
            ])
            _ = scene.playItems([animation], for: duration, easing: .smooth)
        case .zoom(let extent):
            let animation = Animation(pairs: [
                AnimationPair(target: scene.frame, blueprint: CameraZoomFromBlueprint(from: extent))
            ])
            _ = scene.playItems([animation], for: duration, easing: .smooth)
        }
    }
}

// MARK: - Content-arrival tracks (filled by Story.slide after the content runs)

/// A transition track that animates a slide's *own* content on arrival (`.push`,
/// `.morph`). It is enqueued as the slide's first clip but filled *after* the
/// content closure runs, because it needs the slide's introduced entities (and,
/// for morph, the previous slide's as morph sources). Both kinds also **add**
/// their targets at clip begin, so they show during the arrival ahead of the
/// content's own 0-duration `add` clips.
@MainActor
protocol ContentArrivalTrack: AnimationTrackProtocol {
    /// This slide's introduced entities.
    var introduced: [Entity] { get set }
    /// The previous slide's content (morph sources); ignored by `.push`.
    var sources: [Entity] { get set }
}
