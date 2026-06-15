// SlideTransition — the entrance effect played as a viewer arrives at a story
// slide: `story.slide("Solve", transition: .push(from: .right)) { … }`. Two
// families:
//
//   • Content-agnostic (`.fade`, `.zoom`) — a camera move or a transient
//     fullscreen overlay enqueued as the slide's **first clip** (step 0). It
//     plays on arrival and never needs to know what the slide adds.
//   • Content entrance (`.push`) — slides the slide's *own* introduced content in
//     from `edge`, as a layer over the still-visible previous slide (a "card"
//     moving over the board). This one IS content-aware, so `Story.slide` drives
//     it: it runs the slide's content first, then hands the introduced entities
//     to the `ContentPushTrack` and enqueues the slide-in ahead of them (and
//     defers the previous slide's clear to *after* the slide-in, so the old
//     board shows through underneath while the new content slides over it).
//
// Every kind is scrub-safe — the fade introduces/removes its own quad in one
// clip (like `.highlight`), the camera moves ride the `SceneCamera` proxy, and
// the push lerps transforms it captures at clip begin. A geometry/topology-
// matching morph transition is deferred (see the bottom note).

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

// MARK: - Content push (slide the slide's own content in over the previous board)

/// Slides a slide's introduced content in from an edge as one rigid layer. Unlike
/// a normal property track it also **adds** its entities at clip begin, so they
/// are on the board (and sliding) *during* the slide-in even though the slide's
/// own 0-duration `add` clips sit later in the timeline. `Story.slide` fills
/// `entities` after running the content closure.
///
/// Scrub-safe: begin captures each entity's resting position and the one shared
/// off-board offset (frame-sized, toward `edge`); apply lerps offset→rest and
/// keeps them inserted; rewind restores rest and detaches the ones it introduced
/// (so scrubbing before the slide-in takes the new content back off the board).
@MainActor
final class ContentPushTrack: AnimationTrackProtocol {
    let duration: TimeInterval
    let offset: TimeInterval = 0
    let label: String
    private let easing: Easing
    private let edge: Unit

    /// The slide's introduced entities, set by `Story.slide` once the content
    /// closure has run. Empty → the track is an inert no-op.
    var entities: [Entity] = []

    private var hasBegun = false
    private var rests: [Position] = []
    private var delta = Position(0, 0, 0)
    private var inserted: [Entity] = []

    init(edge: Unit, duration: TimeInterval, easing: Easing, label: String) {
        self.edge = edge
        self.duration = max(duration, 0)
        self.easing = easing
        self.label = label
    }

    func begin(in scene: Scene) {
        guard !hasBegun else { return }
        hasBegun = true
        // One shared offset — a whole frame toward `edge` — so the content travels
        // as a rigid card and its internal layout survives.
        let frame = scene.frameBounds
        let direction = edge.vector
        delta = Position(direction.x * frame.size.x, direction.y * frame.size.y, 0)
        rests = entities.map { $0.position }
        // Claim only entities not already on the board (the slide's later `add`
        // clips then no-op them, exactly like write/draw's introducesTarget).
        inserted = entities.filter { $0.scene !== scene }
    }

    func apply(at clipTime: TimeInterval, in scene: Scene) {
        let t = progress(at: clipTime, easing: easing)
        for entity in inserted { scene.insert(entity) }  // idempotent — keeps them shown mid-slide
        for (entity, rest) in zip(entities, rests) {
            entity.position = Position.lerp(rest + delta, rest, t)
        }
    }

    func rewind(in scene: Scene) {
        for (entity, rest) in zip(entities, rests) { entity.position = rest }
        for entity in inserted { scene.detach(entity) }
    }
}

extension ContentPushTrack: ContentArrivalTrack {
    var introduced: [Entity] {
        get { entities }
        set { entities = newValue }
    }
    /// Push slides its content in *over* the previous board — it never reads it.
    var sources: [Entity] {
        get { [] }
        set {}
    }
}

// MARK: - Content morph (TransformMatching the previous slide into this one)

/// Morphs matching content across a slide boundary. `Story.slide` enqueues it as
/// the slide's first clip, then fills `introduced` (this slide's content) and
/// `sources` (the previous slide's). At begin it pairs them by `name`; each pair's
/// **target** then tweens from its **source**'s pose to its own resting pose while
/// the source fades out and the target fades in — plus a path-geometry morph when
/// both ends are `PathEntity`. The previous slide's deferred clear (enqueued after
/// this track) sweeps the faded-out sources at the boundary.
///
/// Scrub-safe: begin captures each pair's start/rest transforms, opacities, and
/// paths and inserts the paired targets; apply lerps pose/opacity (and path) and
/// keeps them inserted; rewind restores the sources to full opacity, the targets
/// to rest, and detaches the targets it introduced (so scrubbing before the morph
/// shows the previous board intact and the new content gone).
@MainActor
final class MorphTransitionTrack: ContentArrivalTrack {
    let duration: TimeInterval
    let offset: TimeInterval = 0
    let label: String
    private let easing: Easing

    var introduced: [Entity] = []
    var sources: [Entity] = []

    private struct Pair {
        let source: Entity
        let target: Entity
        let sourceStart: Transform
        let targetRest: Transform
        // Every node in each subtree that carries opacity, with its base value, so
        // the crossfade cascades through composite entities (equations, arrows,
        // chips) whose opacity lives on child glyphs/parts, not the root.
        let sourceFades: [(node: Entity, base: Real)]
        let targetFades: [(node: Entity, base: Real)]
        let matched: PathMorph.Matched?   // non-nil only when both ends are PathEntities
        let sourcePath: Path?
        let targetPath: Path?
    }

    private var hasBegun = false
    private var pairs: [Pair] = []
    private var insertedTargets: [Entity] = []

    init(duration: TimeInterval, easing: Easing, label: String) {
        self.duration = max(duration, 0)
        self.easing = easing
        self.label = label
    }

    func begin(in scene: Scene) {
        guard !hasBegun else { return }
        hasBegun = true
        // Pair by name: the first incoming target wins a given name.
        var targetByName: [String: Entity] = [:]
        for target in introduced where !target.name.isEmpty {
            if targetByName[target.name] == nil { targetByName[target.name] = target }
        }
        for source in sources {
            guard !source.name.isEmpty, let target = targetByName[source.name] else { continue }
            let sourcePath = (source as? PathEntity)?.path
            let targetPath = (target as? PathEntity)?.path
            let matched = (sourcePath != nil && targetPath != nil)
                ? PathMorph.matched(sourcePath!, targetPath!) : nil
            pairs.append(Pair(
                source: source, target: target,
                sourceStart: source.transform, targetRest: target.transform,
                sourceFades: Self.fadeNodes(of: source), targetFades: Self.fadeNodes(of: target),
                matched: matched, sourcePath: sourcePath, targetPath: targetPath
            ))
        }
        insertedTargets = pairs.map(\.target).filter { $0.scene !== scene }
    }

    func apply(at clipTime: TimeInterval, in scene: Scene) {
        let t = progress(at: clipTime, easing: easing)
        for entity in insertedTargets { scene.insert(entity) }  // idempotent — keep shown mid-morph
        for pair in pairs {
            pair.target.transform = Transform.lerp(pair.sourceStart, pair.targetRest, t)
            for (node, base) in pair.targetFades { Self.setOpacity(node, base * t) }         // fade in
            for (node, base) in pair.sourceFades { Self.setOpacity(node, base * (1 - t)) }   // fade out
            if let matched = pair.matched, let pathTarget = pair.target as? PathEntity {
                if t <= 0 { pathTarget.path = pair.sourcePath! }         // exact endpoints
                else if t >= 1 { pathTarget.path = pair.targetPath! }
                else { pathTarget.path = PathMorph.path(from: PathMorph.interpolate(matched, t: t)) }
            }
        }
    }

    func rewind(in scene: Scene) {
        for pair in pairs {
            pair.target.transform = pair.targetRest
            for (node, base) in pair.targetFades { Self.setOpacity(node, base) }
            for (node, base) in pair.sourceFades { Self.setOpacity(node, base) }  // previous content visible again
            if let targetPath = pair.targetPath, let pathTarget = pair.target as? PathEntity {
                pathTarget.path = targetPath
            }
        }
        for entity in insertedTargets { scene.detach(entity) }
    }

    /// Every node in `entity`'s subtree that carries a `RenderStyleComponent`, with
    /// its base opacity — so the crossfade reaches a composite entity's child
    /// glyphs/parts, not just a root that may have no style of its own.
    private static func fadeNodes(of entity: Entity) -> [(node: Entity, base: Real)] {
        var result: [(node: Entity, base: Real)] = []
        var stack: [Entity] = [entity]
        while let node = stack.popLast() {
            if let style = node.components[RenderStyleComponent.self] {
                result.append((node, style.opacity))
            }
            if let group = node as? HasHierarchy { stack.append(contentsOf: group.children) }
        }
        return result
    }

    private static func setOpacity(_ entity: Entity, _ value: Real) {
        guard var style = entity.components[RenderStyleComponent.self] else { return }
        style.opacity = value
        entity.components[RenderStyleComponent.self] = style
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
