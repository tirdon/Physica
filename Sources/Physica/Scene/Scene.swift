// Scene — entity container, system host, timeline owner, and scripted-API surface.
//
// Script calls (`add`, `play`, `wait`, `pause`) enqueue clips on the timeline; the
// per-frame `update` advances the timeline, runs systems (wall-clock, skippable),
// and finishes with the updater pass so derived state is same-frame consistent.

@MainActor
public final class Scene: Identifiable {
    private static var nextID: UInt64 = 1

    nonisolated public let id: UInt64
    public var name: String = ""

    public let timeline = Timeline()
    public private(set) var entities: [Entity] = []
    let systems = SystemRegistry()

    public var camera = Camera()
    public var background: SceneBackground = .color(.background)
    /// Width/height of the bound viewport; kept current by the engine.
    public var viewportAspect: Real = 1.6

    /// The camera as an animatable entity (Manim's `camera.frame`):
    /// `scene.play(scene.frame.move(to: 6.i), scene.frame.zoom(to: 5))`.
    /// A proxy — it never joins the scene graph.
    public private(set) lazy var frame = SceneCamera(scene: self)

    /// Parallel clip layer for triggered actions, drag feedback, and game
    /// moves — runs every frame, even while the timeline is paused, and is
    /// not part of the scrub history. See `interact(_:for:easing:onInterrupt:)`.
    public let interactions = InteractionRunner()

    /// Pointer-driven drag-and-drop, fed every input event by `dispatch`.
    /// Pause-independent (story mode rests paused while the user drags).
    public let drag = DragCoordinator()

    /// Visible world rect used to resolve `move(to: Unit)`.
    public var frameBounds: Bounds {
        camera.visibleRect(atZ: 0, aspect: viewportAspect)
    }

    /// World-space size of the camera's visible frame — what `move(to: Unit)`
    /// resolves against (10 × 6.25 at the default fit-10 camera, aspect 1.6).
    public var size: SIMD2<Real> {
        SIMD2(frameBounds.size.x, frameBounds.size.y)
    }

    /// Set by the engine via IntersectionObserver; invisible scenes skip updates.
    public internal(set) var isVisible = true

    /// Pair ids whose blueprints `add` already applied — chained descriptors
    /// carry them along, and `play` must not apply them a second time.
    private var consumedPairIDs: Set<UInt64> = []

    /// Latest pointer state in world coordinates (poll from systems).
    public internal(set) var pointer = PointerState()
    var inputContinuations: [UInt64: AsyncStream<InputEvent>.Continuation] = [:]
    var nextInputStreamID: UInt64 = 1

    public init() {
        self.id = Scene.nextID
        Scene.nextID += 1
    }

    // MARK: Entity management (timeline tracks call these)

    func insert(_ entity: Entity, at index: Int? = nil) {
        guard !entity.isRetired else { return }
        guard !entities.contains(where: { $0 === entity }) else { return }
        if let index, index < entities.count {
            entities.insert(entity, at: index)  // re-insert after an erase: keep painter's order
        } else {
            entities.append(entity)
        }
        attach(entity)
    }

    func detach(_ entity: Entity) {
        guard let index = entities.firstIndex(where: { $0 === entity }) else { return }
        entities.remove(at: index)
        entity.scene = nil
    }

    /// Detaches an entity and marks it retired, so structural re-inserts (a
    /// scrub re-seek replaying an `add` clip) skip it for good. For one-shot
    /// tools like a consumed projection operator that must not reappear.
    func retire(_ entity: Entity) {
        entity.isRetired = true
        detach(entity)
    }

    /// Immediately removes an entity from the scene (and its render/hit-test
    /// traversal). For transient entities introduced *outside* the scrub
    /// timeline — e.g. interaction-drawn overlays a caller wants to clear.
    /// Scrub-managed entities (added via `add`) should be removed by scrubbing
    /// or `.erase`, not this.
    public func remove(_ entity: Entity) {
        detach(entity)
    }

    private func attach(_ entity: Entity) {
        entity.scene = self
        if let group = entity as? Group {
            for child in group.children { attach(child) }
        }
    }

    public func performQuery(_ query: EntityQuery) -> [Entity] {
        var result: [Entity] = []
        for root in entities {
            visit(root) { entity in
                if query.predicate(entity) { result.append(entity) }
            }
        }
        return result
    }

    private func visit(_ entity: Entity, _ body: (Entity) -> Void) {
        body(entity)
        if let group = entity as? Group {
            for child in group.children { visit(child, body) }
        }
    }

    // MARK: Systems

    public func registerSystem<S: System>(_ type: S.Type) {
        systems.register(type, scene: self)
    }

    // MARK: Scripted API — every call enqueues a clip and returns an Animation

    /// Adds entities at this point of the timeline (0-duration clip). `Animation`
    /// arguments contribute their target entities and apply their pending changes
    /// instantly. Scrubbing before this clip removes the entities again.
    @discardableResult
    public func add(_ items: any Animatable...) -> Animation {
        addItems(items)
    }

    func addItems(_ items: [any Animatable]) -> Animation {
        var entities: [Entity] = []
        var seen = Set<UInt64>()
        for item in items {
            for target in item.animationTargets where seen.insert(target.id).inserted {
                entities.append(target)
            }
        }

        var tracks: [any AnimationTrackProtocol] = [AddEntitiesTrack(entities: entities)]
        for item in items {
            for pair in item.carriedBlueprints where !consumedPairIDs.contains(pair.id) {
                consumedPairIDs.insert(pair.id)
                tracks.append(
                    pair.blueprint.makeTrack(
                        target: pair.target, duration: 0, offset: 0, easing: .linear, in: self
                    )
                )
            }
        }

        let clip = AnimationClip(label: tracks[0].label, tracks: tracks)
        timeline.enqueue(clip)
        return Animation(
            pairs: entities.map { AnimationPair(target: $0, blueprint: IdentityBlueprint()) },
            duration: .zero
        )
    }

    /// Enqueues a 0-duration clip that drops `entities` at this point of the
    /// timeline — scrub-safe: rewinding past it re-inserts each at its original
    /// root index. Unlike `.erase`, nothing animates (no fade or stroke retract);
    /// the entities simply vanish. Backs `clear(_:)`.
    func dropEntities(_ entities: [Entity]) {
        guard !entities.isEmpty else { return }
        let tracks: [any AnimationTrackProtocol] = entities.map {
            RemoveEntityTrack(entity: $0, at: 0)
        }
        let label = tracks.map(\.label).joined(separator: " + ")
        timeline.enqueue(AnimationClip(label: label, tracks: tracks))
    }

    /// Removes specific entities at this point of the timeline (scrub-safe — a
    /// scrub back re-inserts them at their original depth). Story content persists
    /// by default; `clear`/`clearAll` are how a slide takes things off the board.
    @discardableResult
    public func clear(_ entities: Entity...) -> Animation {
        dropEntities(entities)
        return Animation(pairs: [], duration: .zero)
    }

    /// Requests a fresh slate **when the next slide starts** — at that point every
    /// root except the story globals (entities `scene.add`ed before the slides) is
    /// dropped. Deferred on purpose: the calling slide's content stays visible
    /// through its own duration, and the *last* slide (no next slide) keeps its
    /// content. Read like `defer { s.clearAll() }` — placement in the slide doesn't
    /// matter. What it removes is captured at playback, so it tracks whatever is
    /// actually present; scrubbing back restores it. (No-op outside story mode.)
    @discardableResult
    public func clearAll() -> Animation {
        clearAllPending = true
        return Animation(pairs: [], duration: .zero)
    }

    // MARK: Story scaffolding (set/read by `Story.slide`)

    /// The globals `clearAll()` must keep, kept current by `Story` per slide.
    var storyGlobalIDs: Set<ObjectIdentifier> = []
    /// Set by `clearAll()`, fired by `Story` at the next slide's start.
    private(set) var clearAllPending = false

    /// Enqueues the deferred `clearAll()` now (called by `Story` when the next
    /// slide begins). Protects whatever globals `Story` last published.
    func flushPendingClearAll() {
        guard clearAllPending else { return }
        clearAllPending = false
        let track = ClearAllTrack(protectedIDs: storyGlobalIDs)
        timeline.enqueue(AnimationClip(label: track.label, tracks: [track]))
    }
    /// The previous slide's own-introduced entities, which `addLastState()`
    /// re-adds. Empty outside story building.
    var carryForwardEntities: [Entity] = []
    /// What this slide pulled in via `addLastState` — `Story` reads it to keep
    /// those out of the slide's own-introduced (carry-forward) set.
    private(set) var carriedThisSlide: [Entity] = []

    /// Called by `Story` before each slide's content runs.
    func beginSlideCarry(previous: [Entity]) {
        carryForwardEntities = previous
        carriedThisSlide = []
    }

    /// Story mode: re-introduces the entities the *previous* slide newly added, so
    /// this slide can continue that picture after a `clearAll()`. A no-op on the
    /// first slide / outside story building. Scrub-safe (re-adds through the normal
    /// add clip); if those entities are still present it does nothing.
    @discardableResult
    public func addLastState() -> Animation {
        guard !carryForwardEntities.isEmpty else { return Animation(pairs: [], duration: .zero) }
        carriedThisSlide.append(contentsOf: carryForwardEntities)
        return addItems(carryForwardEntities)
    }

    /// Plays the given animations together as one clip.
    @discardableResult
    public func play(
        _ items: any Animatable...,
        for duration: Duration? = nil,
        easing: Easing? = nil
    ) -> Animation {
        playItems(items, for: duration, easing: easing)
    }

    /// Concrete overload so leading-dot factories resolve:
    /// `scene.play(.write(title))`, `scene.play(.draw(shape), for: 1.2.s)`.
    @discardableResult
    public func play(
        _ items: Animation...,
        for duration: Duration? = nil,
        easing: Easing? = nil
    ) -> Animation {
        playItems(items, for: duration, easing: easing)
    }

    /// Spec alias: `scene.play(group: a1, .init(...))` — offsets/durations respected.
    @discardableResult
    public func play(group: Animation..., easing: Easing? = nil) -> Animation {
        playItems(group.map { $0 }, for: nil, easing: easing)
    }

    /// Result-builder form.
    @discardableResult
    public func play(
        for duration: Duration? = nil,
        easing: Easing? = nil,
        @AnimationBuilder _ content: () -> [Animation]
    ) -> Animation {
        playItems(content().map { $0 }, for: duration, easing: easing)
    }

    /// Builder form with leading duration:
    /// `scene.play(3.s) { circle.move(to: .center); star.opacity(0.8).shift(-1.j) }`
    /// ≡ `scene.play(circle.move(to: .center), ..., for: 3.s)`.
    @discardableResult
    public func play(
        _ duration: Duration,
        easing: Easing? = nil,
        @AnimationBuilder _ content: () -> [Animation]
    ) -> Animation {
        playItems(content().map { $0 }, for: duration, easing: easing)
    }

    /// Imperative composer — one clip, per-animation durations/offsets:
    ///
    ///     scene.play { clip in
    ///         clip.add(circle.move(to: .center), for: 1.s)
    ///         clip.add(star.move(to: .center), for: 2.s)
    ///     }
    @discardableResult
    public func play(easing: Easing? = nil, _ build: (ClipComposer) -> Void) -> Animation {
        let composer = ClipComposer()
        build(composer)
        return playItems(composer.animations, for: nil, easing: easing)
    }

    func playItems(_ items: [any Animatable], for duration: Duration?, easing: Easing?) -> Animation {
        let baked = bakeClip(items, for: duration, easing: easing)
        timeline.enqueue(baked.clip)
        return Animation(pairs: baked.pairs, duration: .interval(baked.clip.duration))
    }

    /// Bakes animatable items into one clip — the shared middle of `play`
    /// (which enqueues on the scrubbable timeline) and `interact` (which runs
    /// the clip NOW on the parallel interaction layer). Pairs `add` already
    /// consumed are filtered identically in both paths; only `add` inserts
    /// into `consumedPairIDs`.
    func bakeClip(
        _ items: [any Animatable], for duration: Duration?, easing: Easing?
    ) -> (clip: AnimationClip, pairs: [AnimationPair]) {
        var tracks: [any AnimationTrackProtocol] = []
        var pairs: [AnimationPair] = []
        var labels: [String] = []
        var introduced: [Entity] = []
        var removals: [(entity: Entity, at: TimeInterval)] = []

        for item in items {
            let animation = item as? Animation
            for pair in item.carriedBlueprints where !consumedPairIDs.contains(pair.id) {
                let resolved = duration ?? animation?.duration ?? pair.blueprint.defaultDuration
                let offset = animation?.offset.interval ?? 0
                let track = pair.blueprint.makeTrack(
                    target: pair.target,
                    duration: resolved.interval,
                    offset: offset,
                    easing: animation?.easing ?? easing ?? .smooth,
                    in: self
                )
                tracks.append(track)
                pairs.append(pair)
                labels.append(track.label)
                if pair.blueprint.introducesTarget, !introduced.contains(where: { $0 === pair.target }) {
                    introduced.append(pair.target)
                }
                if pair.blueprint.removesTargetAtEnd {
                    removals.append((pair.target, offset + resolved.interval))
                }
            }
        }

        // write/draw introduce their target: add it here if no earlier clip did
        // (AddEntitiesTrack only claims entities absent at begin, so an explicit
        // scene.add earlier keeps ownership and this becomes a no-op).
        if !introduced.isEmpty {
            tracks.insert(AddEntitiesTrack(entities: introduced), at: 0)
        }
        // erase removes its target when its window completes.
        for removal in removals {
            tracks.append(RemoveEntityTrack(entity: removal.entity, at: removal.at))
        }

        let clip = AnimationClip(label: labels.joined(separator: " + "), tracks: tracks)
        return (clip, pairs)
    }

    // MARK: Interactions — parallel clips OUTSIDE the scrub history

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

    /// Idle clip — timeline time passes, custom systems keep updating.
    @discardableResult
    public func wait(_ duration: Duration = .seconds(1)) -> Animation {
        let track = WaitTrack(duration: duration.interval)
        timeline.enqueue(AnimationClip(label: track.label, tracks: [track]))
        return Animation(pairs: [], duration: duration)
    }

    /// Suspends one system type for the window of this clip, then resumes it.
    @discardableResult
    public func pause<S: System>(_ system: S.Type, for duration: Duration = .seconds(1)) -> Animation {
        let track = PauseSystemTrack(
            systemID: ObjectIdentifier(system),
            systemName: String(describing: system),
            duration: duration.interval
        )
        timeline.enqueue(AnimationClip(label: track.label, tracks: [track]))
        return Animation(pairs: [], duration: duration)
    }

    // MARK: Frame update

    public func update(deltaTime: TimeInterval) {
        if !timeline.isPaused {
            timeline.advance(by: deltaTime, in: self)
            let context = SceneUpdateContext(
                scene: self,
                deltaTime: deltaTime,
                timelineTime: timeline.currentTime
            )
            systems.update(context: context)
        }
        // Interactions run OUTSIDE the paused gate: story mode rests paused at
        // step boundaries, exactly when triggered actions and drags animate.
        interactions.advance(by: deltaTime, in: self)
        runLayouts()
        runUpdaters()
    }

    /// Scrub to an absolute time: pauses playback (and with it all systems),
    /// replays/rewinds clips deterministically, then re-derives updater state.
    public func seek(to time: TimeInterval) {
        timeline.setPaused(true)
        timeline.seek(to: time, in: self)
        runUpdaters()
    }

    public func resume() {
        timeline.setPaused(false)
    }

    func runUpdaters() {
        for entity in performQuery(.has(UpdaterComponent.self)) {
            guard let component = entity.components[UpdaterComponent.self] else { continue }
            for entry in component.entries {
                entry.run(entity)
            }
        }
    }

    public var debugString: String {
        let entityLines = entities.map { "  " + $0.debugString }
        return "Scene '\(name)' entities(\(entities.count)):\n" + entityLines.joined(separator: "\n")
    }
}

/// Collects animations for the composer form of `scene.play { clip in ... }`.
/// Each `add` keeps its own duration/offset/easing; everything lands in one clip.
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
