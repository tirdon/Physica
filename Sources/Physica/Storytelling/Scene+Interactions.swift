// Scene+Interactions — the parallel interaction layer: `interact(...)` plays a
// clip NOW, alongside the timeline (even while it rests paused at a story step),
// and outside the scrub history. Pairs with InteractionRunner; shares bakeClip
// with `play` so both filter consumed pairs identically.

import PhysicaMath
import PhysicaGeometry
import PhysicaTypesetting

extension Scene {

    /// Plays NOW, in parallel with the timeline (even while it is paused at a
    /// story step). Same surface as `play` — moves, write/draw/erase,
    /// highlight, shake all work — but the clip is not part of the scrubbable
    /// history: seeking never touches it, and entities it introduces persist
    /// across scrubs (the same policy as system-driven state). `onInterrupt`
    /// decides what a slide change does to the clip mid-flight.
    @discardableResult
    public func interact(
        _ items: any Animatable...,
        for duration: Duration? = nil,
        easing: Easing? = nil,
        onInterrupt: InterruptionPolicy = .complete,
        owner: Entity? = nil,
        completion: (@MainActor () -> Void)? = nil
    ) -> InteractionRunner.Handle {
        interactItems(items, for: duration, easing: easing, onInterrupt: onInterrupt, owner: owner, completion: completion)
    }

    /// Concrete overload so leading-dot factories resolve:
    /// `scene.interact(.highlight(box))`, `scene.interact(.shake(token))`.
    @discardableResult
    public func interact(
        _ items: Animation...,
        for duration: Duration? = nil,
        easing: Easing? = nil,
        onInterrupt: InterruptionPolicy = .complete,
        owner: Entity? = nil,
        completion: (@MainActor () -> Void)? = nil
    ) -> InteractionRunner.Handle {
        interactItems(items, for: duration, easing: easing, onInterrupt: onInterrupt, owner: owner, completion: completion)
    }

    func interactItems(
        _ items: [any Animatable],
        for duration: Duration?,
        easing: Easing?,
        onInterrupt: InterruptionPolicy,
        owner: Entity?,
        completion: (@MainActor () -> Void)?
    ) -> InteractionRunner.Handle {
        let baked = bakeClip(items, for: duration, easing: easing)
        return interactions.run(
            clip: baked.clip, policy: onInterrupt, in: self,
            owner: owner ?? interactions.handlerOwner, introduced: baked.introduced, completion: completion
        )
    }

    /// Dismiss the reveal owned by `owner`: stop its in-flight clip and remove the
    /// entities it introduced. `owner` defaults to the entity whose handler is
    /// running, so inside a tap/double-tap handler this is just `scene.interrupt()`.
    /// The owner-keyed peer of `interrupt(_:in:)`.
    public func interrupt(ownedBy owner: Entity? = nil) {
        guard let owner = owner ?? interactions.handlerOwner else { return }
        interactions.interrupt(ownedBy: owner, in: self)
    }

    /// Whether `owner` (default: the running handler's entity) has a live
    /// owner-tagged reveal on the board.
    public func hasInteraction(ownedBy owner: Entity? = nil) -> Bool {
        guard let owner = owner ?? interactions.handlerOwner else { return false }
        return interactions.isOwned(by: owner)
    }
}
