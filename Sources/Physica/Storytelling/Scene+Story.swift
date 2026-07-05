// Scene+Story — the story-authoring surface a slide's content closure reaches
// through `s` (the Scene). Story content is **slide-scoped by default**: entities a
// slide introduces are auto-cleared when the viewer advances to the next slide
// (`Story.slide` computes the set and enqueues a deferred `SlideClearTrack`). Two
// opt-outs live here:
//
//   • `carry(_:)`  — keep specific slide-introduced entities past this slide.
//   • `clear(_:)`  — remove specific entities now, mid-slide (scrub-safe).
//
// Globals (anything `scene.add`ed before/between slides) are never in a slide's
// own-introduced set, so they persist automatically — no separate tracking. The
// one stored field this needs, `carriedThisSlide`, lives on `Scene` because Swift
// extensions can't add stored properties.

import PhysicaFoundation
import PhysicaTypesetting

extension Scene {
    /// Keep `entities` on the board past this slide: excludes them from this
    /// slide's auto-clear, so they persist into later slides until an explicit
    /// `clear`. They must already be on the board (added earlier this slide or
    /// carried in) — `carry` only marks; it enqueues nothing. (No-op outside a
    /// story slide, where `carriedThisSlide` is never read.)
    @discardableResult
    public func carry(_ entities: Entity...) -> Animation {
        carriedThisSlide.append(contentsOf: entities)
        return Animation(pairs: [], duration: .zero)
    }

    /// Removes specific entities at this point of the timeline (scrub-safe — a
    /// scrub back re-inserts them at their original depth). The explicit,
    /// mid-slide counterpart to the automatic end-of-slide clear.
    @discardableResult
    public func clear(_ entities: Entity...) -> Animation {
        dropEntities(entities)
        return Animation(pairs: [], duration: .zero)
    }

    /// Resets the per-slide carry set. Called by `Story` after recording a slide.
    package func resetSlideCarry() {
        carriedThisSlide.removeAll()
    }

    /// Enqueues the deferred end-of-slide auto-clear for `entities` — a
    /// `SlideClearTrack` clip that drops them only when the viewer advances *past*
    /// the boundary (not when resting on it), and re-inserts them on scrub back.
    /// Called by `Story` at the next slide's start. No-op for an empty set.
    package func enqueueSlideClear(_ entities: [Entity]) {
        guard !entities.isEmpty else { return }
        let track = SlideClearTrack(removing: entities)
        timeline.enqueue(AnimationClip(label: track.label, tracks: [track]))
    }
}
