// Scene — entity container, system host, timeline owner, and scripted-API surface.
//
// Script calls (`add`, `play`, `wait`, `pause`) enqueue clips on the timeline; the
// per-frame `update` advances the timeline, runs systems (wall-clock, skippable),
// and finishes with the updater pass so derived state is same-frame consistent.

import PhysicaFoundation
import PhysicaTypesetting

@MainActor
public final class Scene: Identifiable {
    private static var nextID: UInt64 = 1

    nonisolated public let id: UInt64
    public var name: String = ""

    public let timeline = Timeline()
    public private(set) var entities: [Entity] = []
    let systems = SystemRegistry()

    /// Both start from the `Config` defaults captured at scene creation;
    /// assign (or animate `scene.frame`) to override per scene.
    public var camera: Camera
    public var background: SceneBackground
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

    /// Entities the current slide's content marked with `carry(_:)` — `Story`
    /// reads this to exclude them from the slide's auto-clear, then resets it.
    /// (Story state; the rest of the story API lives in `Scene+Story.swift`.)
    package var carriedThisSlide: [Entity] = []

    /// Latest pointer state in world coordinates (poll from systems).
    public internal(set) var pointer = PointerState()
    var inputContinuations: [UInt64: AsyncStream<InputEvent>.Continuation] = [:]
    var nextInputStreamID: UInt64 = 1

    public init() {
        self.id = Scene.nextID
        Scene.nextID += 1
        self.camera = Camera(projection: Config.camera)
        self.background = Config.background
    }

    // MARK: Entity management (timeline tracks call these)

    package func insert(_ entity: Entity, at index: Int? = nil) {
        guard !entity.isRetired else { return }
        guard !contains(entity) else { return }
        // Anchored entities (plots on their plane) attach to their host group,
        // never as roots — the host's transform carries them. Lazy: a
        // factory-made plot stays off the board until its reveal clip.
        if entity.parent == nil, let anchored = entity as? GroupAnchored {
            anchored.anchorGroup.addChild(entity)
            return
        }
        if let index, index < entities.count {
            entities.insert(entity, at: index)  // re-insert after an erase: keep painter's order
        } else {
            entities.append(entity)
        }
        attach(entity)
        adoptDescendantRoots(of: entity)
    }

    /// Whether `entity` already renders in this scene — it is a root, or some
    /// ancestor is. The single membership truth; the weak `scene` pointer is a
    /// cache maintained by insert/detach, never the decider (a transient
    /// animation bag sets `parent` on members but never joins the scene, so the
    /// walk also checks each ancestor level against the roots directly).
    public func contains(_ entity: Entity) -> Bool {
        var node: Entity? = entity
        while let current = node {
            if entities.contains(where: { $0 === current }) { return true }
            node = current.parent
        }
        return false
    }

    /// Roots a group insert adopted (they render through the group now), with
    /// their old indices — detaching that group restores them, so every
    /// insert/detach pair stays exactly inverse and scrubbing across a
    /// child-first add round-trips.
    private var adoptedRootsByGroup: [UInt64: [(entity: Entity, index: Int)]] = [:]

    /// A group insert may arrive *after* one of its descendants was added as a
    /// root (child-first order). The descendant now renders through the group,
    /// so its root slot must go — it stays in the scene, just not as a root.
    /// The slot is remembered and restored by `detach` (scrub symmetry).
    private func adoptDescendantRoots(of entity: Entity) {
        guard entity is Group else { return }
        var adopted: [(entity: Entity, index: Int)] = []
        for (index, root) in entities.enumerated()
        where root !== entity && isDescendant(root, of: entity) {
            adopted.append((root, index))
        }
        guard !adopted.isEmpty else { return }
        entities.removeAll { root in adopted.contains { $0.entity === root } }
        adoptedRootsByGroup[entity.id] = adopted
    }

    private func isDescendant(_ entity: Entity, of ancestor: Entity) -> Bool {
        var node = entity.parent
        while let current = node {
            if current === ancestor { return true }
            node = current.parent
        }
        return false
    }

    package func detach(_ entity: Entity) {
        if let index = entities.firstIndex(where: { $0 === entity }) {
            entities.remove(at: index)
            clearScene(entity)
            // Undo this group's adoption: descendants that were standalone
            // roots before it arrived become roots again, at their old indices.
            if let adopted = adoptedRootsByGroup.removeValue(forKey: entity.id) {
                for entry in adopted.sorted(by: { $0.index < $1.index }) {
                    insert(entry.entity, at: entry.index)
                }
            }
            return
        }
        // Not a root: a child leaving through its parent group (a plot reveal
        // rewinding, an interaction overlay clearing). removeChild clears the
        // entity's own cached pointer; clearScene sweeps its subtree's.
        if let parent = entity.parent as? Group,
           parent.children.contains(where: { $0 === entity }) {
            parent.removeChild(entity)
            clearScene(entity)
        }
    }

    /// Mirrors `attach` — a detached root's descendants leave the scene with it
    /// (the pointer is a cache; leaving children stale was the old dual-encoding
    /// bug that made re-adds after a slide clear silently no-op).
    private func clearScene(_ entity: Entity) {
        entity.scene = nil
        if let group = entity as? Group {
            for child in group.children { clearScene(child) }
        }
    }

    /// Detaches an entity and marks it retired, so structural re-inserts (a
    /// scrub re-seek replaying an `add` clip) skip it for good. For one-shot
    /// tools like a consumed projection operator that must not reappear.
    package func retire(_ entity: Entity) {
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

    /// Optional-tolerant `add`: nil items are dropped; if nothing remains,
    /// nothing is enqueued and the result is nil. Optionally-present content
    /// (`try?` math, an optional face's labels) flows through without `if let`.
    @discardableResult
    public func add(_ items: (any Animatable)?...) -> Animation? {
        let present = items.compactMap { $0 }
        guard !present.isEmpty else { return nil }
        return addItems(present)
    }

    package func addItems(_ items: [any Animatable]) -> Animation {
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

    /// Animates the camera back to the default framing — origin-centered,
    /// `orthographicFit(extent: 10)` — undoing any ad-hoc `frame.shift`/`zoom`.
    /// Convenience for `play(frame.reset(), for:)`, so a slide reads `s.reset()`.
    @discardableResult
    public func reset(for duration: Duration? = nil, easing: Easing? = nil) -> Animation {
        play(frame.reset(), for: duration, easing: easing)
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

    /// Optional-tolerant `play`: nil items are dropped. All nil → nothing is
    /// enqueued (no clip, no time passes — exactly what an `if let` guard did)
    /// and the result is nil.
    @discardableResult
    public func play(
        _ items: (any Animatable)?...,
        for duration: Duration? = nil,
        easing: Easing? = nil
    ) -> Animation? {
        let present = items.compactMap { $0 }
        guard !present.isEmpty else { return nil }
        return playItems(present, for: duration, easing: easing)
    }

    /// Optional concrete overload — leading-dot factories with optional content:
    /// `scene.play(.write(formula), for: 2.5.s)` where `formula: TextEntity?`.
    @discardableResult
    public func play(
        _ items: Animation?...,
        for duration: Duration? = nil,
        easing: Easing? = nil
    ) -> Animation? {
        let present = items.compactMap { $0 }
        guard !present.isEmpty else { return nil }
        return playItems(present.map { $0 }, for: duration, easing: easing)
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

    package func playItems(_ items: [any Animatable], for duration: Duration?, easing: Easing?) -> Animation {
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
    ) -> (clip: AnimationClip, pairs: [AnimationPair], introduced: [Entity]) {
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
        return (clip, pairs, introduced)
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
