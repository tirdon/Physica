// Content push — slide the slide's own content in over the previous board.

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
import PhysicaFoundation

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
        inserted = entities.filter { !scene.contains($0) }
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
