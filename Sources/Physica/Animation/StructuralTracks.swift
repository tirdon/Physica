// Structural tracks — mutate the scene graph rather than a property: add/remove
// entities, the per-slide auto-clear, system pauses, and waits. See Tracks.swift
// for the AnimationTrackProtocol contract.

// MARK: - Structural tracks

/// 0-duration track that adds entities (and on rewind, removes them again).
import PhysicaFoundation
import PhysicaTypesetting

@MainActor
package final class AddEntitiesTrack: AnimationTrackProtocol {
    package let duration: TimeInterval = 0
    package let offset: TimeInterval = 0
    package let label: String

    private let entities: [Entity]
    /// Entities this track actually inserted (so rewind doesn't evict pre-existing ones).
    private var inserted: [Entity]?

    init(entities: [Entity]) {
        self.entities = entities
        self.label = "add(" + entities.map { name(of: $0) }.joined(separator: ", ") + ")"
    }

    /// The entities this track was built to introduce — known at build time (the
    /// `inserted` subset is only computed at runtime `begin`). `Story` scans these
    /// across a slide's clips to find what to tear down at the slide's end.
    package var introducedTargets: [Entity] { entities }

    package func begin(in scene: Scene) {
        guard inserted == nil else { return }
        inserted = entities.filter { !scene.contains($0) }
    }

    package func apply(at clipTime: TimeInterval, in scene: Scene) {
        for entity in inserted ?? [] {
            scene.insert(entity)
        }
    }

    package func rewind(in scene: Scene) {
        for entity in inserted ?? [] {
            scene.detach(entity)
        }
    }
}

/// 0-duration track at `offset` (an erase animation's end) that removes its
/// entity from the scene. Scrubbing back re-inserts at the original root index
/// so painter's order and debug-label paths survive the round trip.
@MainActor
package final class RemoveEntityTrack: AnimationTrackProtocol {
    package let duration: TimeInterval = 0
    package let offset: TimeInterval
    package let label: String

    private let entity: Entity
    private var hasBegun = false
    /// Root index at clip start; nil = not a scene root then.
    private var rootIndex: Int?
    /// Child slot at clip start, for targets living inside a group (a plot on
    /// its plane): removal detaches from the parent, rewind re-inserts there.
    private var childSlot: (parent: Group, index: Int)?

    init(entity: Entity, at offset: TimeInterval) {
        self.entity = entity
        self.offset = max(offset, 0)
        self.label = "remove(\(name(of: entity)))"
    }

    /// The entity this track removes — `Story` reads it to exclude net-transient
    /// entities (a `.fade` overlay, a `.highlight` border introduced *and* removed
    /// inside one slide) from the slide's carry-forward set.
    package var removedTarget: Entity { entity }

    private func resolveSlot(in scene: Scene) {
        rootIndex = scene.entities.firstIndex { $0 === entity }
        if rootIndex == nil,
           let parent = entity.parent as? Group,
           let index = parent.children.firstIndex(where: { $0 === entity }) {
            childSlot = (parent, index)
        }
    }

    package func begin(in scene: Scene) {
        guard !hasBegun else { return }
        hasBegun = true
        resolveSlot(in: scene)
    }

    package func apply(at clipTime: TimeInterval, in scene: Scene) {
        // Targets introduced by this same clip (highlight borders) aren't
        // in the graph yet at begin — resolve once the AddEntitiesTrack ran.
        if rootIndex == nil, childSlot == nil {
            resolveSlot(in: scene)
        }
        if let index = rootIndex {
            if clipTime >= offset {
                scene.detach(entity)
            } else {
                scene.insert(entity, at: index)
            }
        } else if let slot = childSlot {
            if clipTime >= offset {
                scene.detach(entity)
            } else if !slot.parent.children.contains(where: { $0 === entity }) {
                slot.parent.insertChild(entity, at: slot.index)
            }
        }
    }

    package func rewind(in scene: Scene) {
        if let index = rootIndex {
            scene.insert(entity, at: index)
        } else if let slot = childSlot,
                  !slot.parent.children.contains(where: { $0 === entity }) {
            slot.parent.insertChild(entity, at: slot.index)
        }
    }
}

/// Zero-duration track that drops a **fixed** set of entities — a story slide's
/// own-introduced content (minus what it `carry`-ed or already removed), computed
/// at build time by `Story.slide`. Each entity's root index is captured at `begin`
/// (runtime), so scrubbing back re-inserts it at its original depth (ascending, so
/// the indices rebuild the original order). Powers the automatic end-of-slide
/// clear; enqueued by `Scene.enqueueSlideClear`.
///
/// Truly zero-duration, so it neither adds a step boundary nor shifts the slide's
/// start/end times. `apply` always removes (reaching the boundary clears the
/// previous slide); `rewind` re-inserts (scrubbing back restores it). The
/// "previous slide stays visible until you move forward" promise is the player's
/// job — `StoryPlayer` rests one beat *before* a deferred-clear boundary, so the
/// clear is never reached at that rest.
@MainActor
final class SlideClearTrack: AnimationTrackProtocol {
    let duration: TimeInterval = 0
    let offset: TimeInterval = 0
    let label: String

    private let targets: [Entity]
    private var captured = false
    /// Root index, or (parent, index) for a plane-child target (a plot on its
    /// board) — same root-vs-child distinction `RemoveEntityTrack` resolves,
    /// since a slide's introduced set can include either kind. Sorted ascending
    /// by index so rewind's re-insertion rebuilds each container's original
    /// order (root and child indices index different arrays, but sorting them
    /// together is still safe: entries sharing a container keep their relative
    /// order, and entries in different containers never interact).
    private var removals: [(entity: Entity, index: Int, parent: Group?)] = []

    init(removing targets: [Entity]) {
        self.targets = targets
        self.label = "autoClear(\(targets.count))"
    }

    func begin(in scene: Scene) {
        guard !captured else { return }
        captured = true
        removals = targets
            .compactMap { entity -> (entity: Entity, index: Int, parent: Group?)? in
                if let index = scene.entities.firstIndex(where: { $0 === entity }) {
                    return (entity, index, nil)
                }
                if let parent = entity.parent as? Group,
                   let index = parent.children.firstIndex(where: { $0 === entity }) {
                    return (entity, index, parent)
                }
                return nil
            }
            .sorted { $0.index < $1.index }
    }

    func apply(at clipTime: TimeInterval, in scene: Scene) {
        for removal in removals { scene.detach(removal.entity) }
    }

    func rewind(in scene: Scene) {
        for removal in removals {
            if let parent = removal.parent {
                if !parent.children.contains(where: { $0 === removal.entity }) {
                    parent.insertChild(removal.entity, at: removal.index)
                }
            } else {
                scene.insert(removal.entity, at: removal.index)
            }
        }
    }
}

/// Suspends one system type for the active window of the clip.
@MainActor
final class PauseSystemTrack: AnimationTrackProtocol {
    let duration: TimeInterval
    let offset: TimeInterval = 0
    let label: String

    private let systemID: ObjectIdentifier

    init(systemID: ObjectIdentifier, systemName: String, duration: TimeInterval) {
        self.systemID = systemID
        self.duration = max(duration, 0)
        self.label = "pause(\(systemName))"
    }

    func begin(in scene: Scene) {}

    func apply(at clipTime: TimeInterval, in scene: Scene) {
        scene.systems.setSuspended(clipTime < duration, typeID: systemID)
    }

    func rewind(in scene: Scene) {
        scene.systems.setSuspended(false, typeID: systemID)
    }
}

/// Empty clip body for `scene.wait(...)` — time passes, systems keep running.
@MainActor
final class WaitTrack: AnimationTrackProtocol {
    let duration: TimeInterval
    let offset: TimeInterval = 0
    let label: String

    init(duration: TimeInterval) {
        self.duration = max(duration, 0)
        self.label = "wait(\(fmt(duration, decimals: 2))s)"
    }

    func begin(in scene: Scene) {}
    func apply(at clipTime: TimeInterval, in scene: Scene) {}
    func rewind(in scene: Scene) {}
}
