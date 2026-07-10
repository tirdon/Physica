// ClipComposer — collects animations for the composer form
// `scene.play { clip in ... }`: each `add` keeps its own duration/offset/easing
// and everything lands in one clip.

/// Collects animations for the composer form of `scene.play { clip in ... }`.
/// Each `add` keeps its own duration/offset/easing; everything lands in one clip.
import PhysicaFoundation
import PhysicaTypesetting

@MainActor
public final class ClipComposer {
    var animations: [Animation] = []

    @discardableResult
    public func add(
        _ item: any Animatable,
        for duration: Duration? = nil,
        offset: Duration? = nil,
        easing: Easing? = nil
    ) -> Animation {
        append(item, for: duration, offset: offset, easing: easing)
    }

    /// Concrete overload so leading-dot factories resolve:
    /// `clip.add(.erase(shape), for: 1.s)`.
    @discardableResult
    public func add(
        _ animation: Animation,
        for duration: Duration? = nil,
        offset: Duration? = nil,
        easing: Easing? = nil
    ) -> Animation {
        append(animation, for: duration, offset: offset, easing: easing)
    }

    /// Optional-tolerant composer add: a nil item contributes nothing.
    @discardableResult
    public func add(
        _ item: (any Animatable)?,
        for duration: Duration? = nil,
        offset: Duration? = nil,
        easing: Easing? = nil
    ) -> Animation? {
        guard let item else { return nil }
        return append(item, for: duration, offset: offset, easing: easing)
    }

    /// Optional concrete overload — `clip.add(.write(formula), for: 1.s)` with
    /// `formula: TextEntity?`.
    @discardableResult
    public func add(
        _ animation: Animation?,
        for duration: Duration? = nil,
        offset: Duration? = nil,
        easing: Easing? = nil
    ) -> Animation? {
        guard let animation else { return nil }
        return append(animation, for: duration, offset: offset, easing: easing)
    }

    /// The single worker behind every `add` overload (non-overloaded on
    /// purpose, so the optional forwards can never re-enter themselves).
    private func append(
        _ item: any Animatable, for duration: Duration?, offset: Duration?, easing: Easing?
    ) -> Animation {
        let base = item as? Animation
        let animation = Animation(
            pairs: item.carriedBlueprints,
            duration: duration ?? base?.duration,
            offset: offset ?? base?.offset ?? .zero,
            easing: easing ?? base?.easing
        )
        animations.append(animation)
        return animation
    }
}

/// No-op blueprint used when an API must return an Animation without scheduling work.
struct IdentityBlueprint: AnimationBlueprint {
    var defaultDuration: Duration { .zero }
    var debugLabel: String { "identity" }

    func makeTrack(
        target: Entity, duration: TimeInterval, offset: TimeInterval, easing: Easing, in scene: Scene
    ) -> any AnimationTrackProtocol {
        WaitTrack(duration: 0)
    }
}
