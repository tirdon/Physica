// Scene+Interactions — the parallel interaction layer: `interact(...)` plays a
// clip NOW, alongside the timeline (even while it rests paused at a story step),
// and outside the scrub history. Pairs with InteractionRunner; shares bakeClip
// with `play` so both filter consumed pairs identically.

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
        completion: (@MainActor () -> Void)? = nil
    ) -> InteractionRunner.Handle {
        interactItems(items, for: duration, easing: easing, onInterrupt: onInterrupt, completion: completion)
    }

    /// Concrete overload so leading-dot factories resolve:
    /// `scene.interact(.highlight(box))`, `scene.interact(.shake(token))`.
    @discardableResult
    public func interact(
        _ items: Animation...,
        for duration: Duration? = nil,
        easing: Easing? = nil,
        onInterrupt: InterruptionPolicy = .complete,
        completion: (@MainActor () -> Void)? = nil
    ) -> InteractionRunner.Handle {
        interactItems(items, for: duration, easing: easing, onInterrupt: onInterrupt, completion: completion)
    }

    func interactItems(
        _ items: [any Animatable],
        for duration: Duration?,
        easing: Easing?,
        onInterrupt: InterruptionPolicy,
        completion: (@MainActor () -> Void)?
    ) -> InteractionRunner.Handle {
        let baked = bakeClip(items, for: duration, easing: easing)
        return interactions.run(clip: baked.clip, policy: onInterrupt, in: self, completion: completion)
    }
}
