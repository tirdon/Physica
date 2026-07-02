// Fade transition — a transient fullscreen quad that fades from opaque to clear
// as the slide arrives (introduced and removed by its own clip, like `.highlight`).

import PhysicaMath
import PhysicaGeometry
import PhysicaKernel

struct FadeTransitionBlueprint: AnimationBlueprint {
    var debugLabel: String { "transition.fade()" }
    var defaultDuration: Duration { .seconds(0.7) }
    var introducesTarget: Bool { true }
    var removesTargetAtEnd: Bool { true }

    func makeTrack(
        target: Entity, duration: TimeInterval, offset: TimeInterval, easing: Easing, in scene: Scene
    ) -> any AnimationTrackProtocol {
        FadeTransitionTrack(
            overlay: target, duration: duration, offset: offset, easing: easing,
            label: "transition.\(debugLabel)"
        )
    }
}

@MainActor
final class FadeTransitionTrack: AnimationTrackProtocol {
    let duration: TimeInterval
    let offset: TimeInterval
    let label: String
    private let easing: Easing
    private let overlay: Entity
    private var hasBegun = false

    init(
        overlay: Entity, duration: TimeInterval, offset: TimeInterval, easing: Easing, label: String
    ) {
        self.overlay = overlay
        self.duration = max(duration, 0)
        self.offset = max(offset, 0)
        self.easing = easing
        self.label = label
    }

    func begin(in scene: Scene) {
        guard !hasBegun else { return }
        hasBegun = true
        guard let pathEntity = overlay as? PathEntity else { return }
        // Cover the frame at clip start, oversized a touch so the edges are safe.
        let frame = scene.frameBounds
        pathEntity.path = Path.rect(
            width: frame.size.x * 1.1 + 1, height: frame.size.y * 1.1 + 1,
            center: SIMD2(frame.center.x, frame.center.y)
        )
    }

    func apply(at clipTime: TimeInterval, in scene: Scene) {
        guard var style = overlay.components[RenderStyleComponent.self] else { return }
        style.opacity = 1 - progress(at: clipTime, easing: easing)  // opaque → clear
        overlay.components[RenderStyleComponent.self] = style
    }

    func rewind(in scene: Scene) {
        guard var style = overlay.components[RenderStyleComponent.self] else { return }
        style.opacity = 1
        overlay.components[RenderStyleComponent.self] = style
    }
}
