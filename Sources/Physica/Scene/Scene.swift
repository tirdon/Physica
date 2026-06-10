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
    public var background = Color.background
    /// Width/height of the bound viewport; kept current by the engine.
    public var viewportAspect: Real = 1.6

    /// Visible world rect used to resolve `move(to: Unit)`.
    public var frameBounds: Bounds {
        camera.visibleRect(atZ: 0, aspect: viewportAspect)
    }

    /// Set by the engine via IntersectionObserver; invisible scenes skip updates.
    public internal(set) var isVisible = true

    /// Latest pointer state in world coordinates (poll from systems).
    public internal(set) var pointer = PointerState()
    var inputContinuations: [UInt64: AsyncStream<InputEvent>.Continuation] = [:]
    var nextInputStreamID: UInt64 = 1

    public init() {
        self.id = Scene.nextID
        Scene.nextID += 1
    }

    // MARK: Entity management (timeline tracks call these)

    func insert(_ entity: Entity) {
        guard !entities.contains(where: { $0 === entity }) else { return }
        entities.append(entity)
        attach(entity)
    }

    func detach(_ entity: Entity) {
        guard let index = entities.firstIndex(where: { $0 === entity }) else { return }
        entities.remove(at: index)
        entity.scene = nil
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
            for (target, blueprint) in item.carriedBlueprints {
                tracks.append(
                    blueprint.makeTrack(target: target, duration: 0, offset: 0, easing: .linear, in: self)
                )
            }
        }

        let clip = AnimationClip(label: tracks[0].label, tracks: tracks)
        timeline.enqueue(clip)
        return Animation(pairs: entities.map { ($0, IdentityBlueprint()) }, duration: .zero)
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

    func playItems(_ items: [any Animatable], for duration: Duration?, easing: Easing?) -> Animation {
        var tracks: [any AnimationTrackProtocol] = []
        var pairs: [(target: Entity, blueprint: any AnimationBlueprint)] = []
        var labels: [String] = []

        for item in items {
            let animation = item as? Animation
            for (target, blueprint) in item.carriedBlueprints {
                let resolved = duration ?? animation?.duration ?? blueprint.defaultDuration
                let track = blueprint.makeTrack(
                    target: target,
                    duration: resolved.interval,
                    offset: animation?.offset.interval ?? 0,
                    easing: animation?.easing ?? easing ?? .smooth,
                    in: self
                )
                tracks.append(track)
                pairs.append((target, blueprint))
                labels.append(track.label)
            }
        }

        let clip = AnimationClip(label: labels.joined(separator: " + "), tracks: tracks)
        timeline.enqueue(clip)
        return Animation(pairs: pairs, duration: .interval(clip.duration))
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
