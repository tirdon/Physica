// Zoom transition — push in/out: the camera starts at `from` and eases to the
// slide's resting zoom, riding the `SceneCamera` proxy like any camera clip.

import PhysicaFoundation

struct CameraZoomFromBlueprint: AnimationBlueprint {
    let from: Real
    var debugLabel: String { "transition.zoom(from: \(fmt(from, decimals: 2)))" }
    var defaultDuration: Duration { .seconds(0.8) }

    func makeTrack(
        target: Entity, duration: TimeInterval, offset: TimeInterval, easing: Easing, in scene: Scene
    ) -> any AnimationTrackProtocol {
        CameraZoomFromTrack(
            camera: target, from: from, duration: duration, offset: offset, easing: easing,
            label: "camera.\(debugLabel)"
        )
    }
}

@MainActor
final class CameraZoomFromTrack: AnimationTrackProtocol {
    let duration: TimeInterval
    let offset: TimeInterval
    let label: String
    private let easing: Easing
    private let camera: Entity
    private let from: Real
    private var rest: Real?

    init(
        camera: Entity, from: Real, duration: TimeInterval, offset: TimeInterval,
        easing: Easing, label: String
    ) {
        self.camera = camera
        self.from = from
        self.duration = max(duration, 0)
        self.offset = max(offset, 0)
        self.easing = easing
        self.label = label
    }

    func begin(in scene: Scene) {
        guard rest == nil, let sceneCamera = camera as? SceneCamera else { return }
        rest = sceneCamera.zoomExtent
    }

    func apply(at clipTime: TimeInterval, in scene: Scene) {
        guard let rest, let sceneCamera = camera as? SceneCamera else { return }
        let t = progress(at: clipTime, easing: easing)
        sceneCamera.zoomExtent = from + (rest - from) * t  // from → rest
    }

    func rewind(in scene: Scene) {
        if let rest, let sceneCamera = camera as? SceneCamera { sceneCamera.zoomExtent = rest }
    }
}
