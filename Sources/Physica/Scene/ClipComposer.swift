// ClipComposer — collects animations for the composer form
// `scene.play { clip in ... }`: each `add` keeps its own duration/offset/easing
// and everything lands in one clip.

/// Collects animations for the composer form of `scene.play { clip in ... }`.
/// Each `add` keeps its own duration/offset/easing; everything lands in one clip.
import PhysicaMath
import PhysicaGeometry
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

    /// Concrete overload so leading-dot factories resolve:
    /// `clip.add(.erase(shape), for: 1.s)`.
    @discardableResult
    public func add(
        _ animation: Animation,
        for duration: Duration? = nil,
        offset: Duration? = nil,
        easing: Easing? = nil
    ) -> Animation {
        add(animation as any Animatable, for: duration, offset: offset, easing: easing)
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
