// SlideTransition — the entrance effect played as a viewer arrives at a story
// slide: `story.slide("Forces", transition: .push(from: .right)) { … }`.
//
// A transition is enqueued as the slide's **first clip** (before the slide's
// content), so it becomes step 0 and plays on arrival. It is content-agnostic —
// either a camera move (push/zoom, riding the `SceneCamera` proxy) or a transient
// fullscreen overlay (fade, which introduces and removes its own quad within the
// one clip, exactly like `.highlight`'s border). That keeps it fully scrub-safe
// and means it never needs to know what the slide adds. A geometry/topology-
// matching morph transition is deferred (see the bottom note).

@MainActor
public struct SlideTransition: Sendable {
    enum Kind: Sendable {
        case none
        case fade(Color?)
        case push(Unit)
        case zoom(Real)
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

    /// The board slides in from `edge`: the camera starts offset one frame toward
    /// `edge` and eases to rest, so content enters from that side.
    public static func push(from edge: Unit, duration: Duration = .seconds(0.8)) -> SlideTransition {
        SlideTransition(kind: .push(edge), duration: duration)
    }

    /// Push in/out: the camera starts at zoom `extent` and eases to the slide's
    /// resting zoom (larger extent = starts further out).
    public static func zoom(from extent: Real, duration: Duration = .seconds(0.8)) -> SlideTransition {
        SlideTransition(kind: .zoom(extent), duration: duration)
    }

    /// Enqueues the transition clip on `scene` (no-op for `.none`). Called by
    /// `Story.slide` right before the slide's content runs.
    func enqueue(on scene: Scene) {
        switch kind {
        case .none:
            return
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
        case .push(let edge):
            let animation = Animation(pairs: [
                AnimationPair(target: scene.frame, blueprint: CameraSlideBlueprint(edge: edge))
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

// MARK: - Fade overlay (transient fullscreen quad)

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

// MARK: - Camera push (slide the board in from an edge)

struct CameraSlideBlueprint: AnimationBlueprint {
    let edge: Unit
    var debugLabel: String { "transition.push(from: .\(edge))" }
    var defaultDuration: Duration { .seconds(0.8) }

    func makeTrack(
        target: Entity, duration: TimeInterval, offset: TimeInterval, easing: Easing, in scene: Scene
    ) -> any AnimationTrackProtocol {
        CameraSlideTrack(
            camera: target, edge: edge, duration: duration, offset: offset, easing: easing,
            label: "camera.\(debugLabel)"
        )
    }
}

@MainActor
final class CameraSlideTrack: AnimationTrackProtocol {
    let duration: TimeInterval
    let offset: TimeInterval
    let label: String
    private let easing: Easing
    private let camera: Entity
    private let edge: Unit
    private var rest: Position?
    private var delta: Position?

    init(
        camera: Entity, edge: Unit, duration: TimeInterval, offset: TimeInterval,
        easing: Easing, label: String
    ) {
        self.camera = camera
        self.edge = edge
        self.duration = max(duration, 0)
        self.offset = max(offset, 0)
        self.easing = easing
        self.label = label
    }

    func begin(in scene: Scene) {
        guard rest == nil else { return }
        rest = camera.position
        // Offset by one visible frame toward the edge — captured at clip start so
        // it tracks whatever zoom the slide arrives at.
        let frame = scene.frameBounds
        let direction = edge.vector
        delta = Position(direction.x * frame.size.x, direction.y * frame.size.y, 0)
    }

    func apply(at clipTime: TimeInterval, in scene: Scene) {
        guard let rest, let delta else { return }
        let t = progress(at: clipTime, easing: easing)
        camera.position = Position.lerp(rest + delta, rest, t)  // offset → rest
    }

    func rewind(in scene: Scene) {
        if let rest { camera.position = rest }
    }
}

// MARK: - Camera zoom (push in/out to the resting zoom)

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

// Deferred: a geometry/topology-matching morph transition (`.morph`) would lean on
// the existing `PathMorph` / `PolylineMorphTrack` / `MeshMorph` machinery to tween
// matching shapes across a slide boundary. Out of scope for this pass.
