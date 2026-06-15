// InteractionRunner — the parallel, non-scrubbable clip layer.
//
// Button actions, drag feedback, and game-move animations play NOW, alongside
// whatever the main timeline is doing — including while it is paused at a
// story step. The runner reuses AnimationClip wholesale (same tracks, same
// begin/apply contract) but its clips are NOT part of the scrub history:
// `scene.seek` never touches them, and structural effects (entities a
// triggered `.draw` introduced, equation rows appended by a move) persist
// across scrubs — the same policy as system-driven physics state.

/// What happens to an in-flight interaction clip when it is interrupted
/// (slide change, explicit cancel).
public enum InterruptionPolicy: Sendable, Equatable {
    /// Jump to the end state instantly — the default; game results must land.
    case complete
    /// Rewind to the captured start (transient FX, abandoned gestures).
    case cancel
}

@MainActor
public final class InteractionRunner {
    public struct Handle: Sendable, Equatable, Hashable {
        let id: UInt64
    }

    private struct Active {
        let handle: Handle
        let clip: AnimationClip
        let policy: InterruptionPolicy
        var time: TimeInterval
        let owner: Entity?
        let completion: (@MainActor () -> Void)?
    }

    private var active: [Active] = []
    /// Entities each owner's interaction introduced, retained past the clip's own
    /// lifetime so `interrupt(ownedBy:)` can still clear a reveal that already
    /// finished drawing and is just persisting. Keyed by `owner.id`.
    private var introducedByOwner: [UInt64: [Entity]] = [:]
    /// The entity whose tap/double-tap handler is currently running. The drag
    /// coordinator sets it around a handler call so interactions started inside
    /// the handler default to that owner — callers write `scene.interact(.draw(x))`
    /// / `scene.interrupt()` with no explicit owner.
    var handlerOwner: Entity?
    private var nextHandleID: UInt64 = 1

    public var isIdle: Bool { active.isEmpty }

    /// Begins the clip immediately (start state applies this frame) and
    /// advances it on subsequent `Scene.update`s. Zero-duration clips finish
    /// on the spot.
    @discardableResult
    func run(
        clip: AnimationClip,
        policy: InterruptionPolicy,
        in scene: Scene,
        owner: Entity? = nil,
        introduced: [Entity] = [],
        completion: (@MainActor () -> Void)? = nil
    ) -> Handle {
        let handle = Handle(id: nextHandleID)
        nextHandleID += 1
        // Record before the zero-duration early-out so even an instant reveal is
        // dismissible by its owner.
        if let owner, !introduced.isEmpty {
            introducedByOwner[owner.id, default: []].append(contentsOf: introduced)
        }
        clip.begin(in: scene)
        if clip.duration <= 0 {
            clip.apply(at: 0, in: scene)
            completion?()
            return handle
        }
        clip.apply(at: 0, in: scene)
        active.append(Active(handle: handle, clip: clip, policy: policy, time: 0, owner: owner, completion: completion))
        return handle
    }

    /// Called from `Scene.update` every frame — OUTSIDE the paused gate.
    func advance(by deltaTime: TimeInterval, in scene: Scene) {
        guard !active.isEmpty else { return }
        var finishedHandles: [Handle] = []
        for index in active.indices {
            active[index].time += deltaTime
            let entry = active[index]
            entry.clip.apply(at: min(entry.time, entry.clip.duration), in: scene)
            if entry.time >= entry.clip.duration {
                finishedHandles.append(entry.handle)
            }
        }
        let finished = active.filter { finishedHandles.contains($0.handle) }
        active.removeAll { finishedHandles.contains($0.handle) }
        for entry in finished {
            entry.completion?()
        }
    }

    /// Resolve one in-flight clip by its policy. No-op for finished handles.
    public func interrupt(_ handle: Handle, in scene: Scene) {
        guard let index = active.firstIndex(where: { $0.handle == handle }) else { return }
        let entry = active.remove(at: index)
        finish(entry, in: scene)
    }

    /// Dismiss a reveal owned by `owner`: drop any clip it started (so a live
    /// `.draw` stops re-inserting its target every advance) and remove every
    /// entity that interaction introduced — whether still mid-flight or already
    /// finished and persisting. The owner-keyed counterpart to `interrupt(_:in:)`.
    /// Order matters: clear the active clip before detaching, or the next advance
    /// would re-insert what we just removed.
    public func interrupt(ownedBy owner: Entity, in scene: Scene) {
        active.removeAll { $0.owner === owner }
        for entity in introducedByOwner[owner.id] ?? [] {
            scene.detach(entity)
        }
        introducedByOwner[owner.id] = nil
    }

    /// Whether `owner` has a live reveal (introduced entities still on the board).
    /// Lets a re-tap skip restacking without any captured state.
    public func isOwned(by owner: Entity) -> Bool {
        !(introducedByOwner[owner.id]?.isEmpty ?? true)
    }

    /// Resolve everything in flight — the story player calls this on slide
    /// changes so no token strands mid-air. Owner-tagged reveals are cleared too,
    /// so a tapped-open overlay never leaks into the next slide.
    public func interruptAll(in scene: Scene) {
        let entries = active
        active.removeAll()
        for entry in entries {
            finish(entry, in: scene)
        }
        for entities in introducedByOwner.values {
            for entity in entities { scene.detach(entity) }
        }
        introducedByOwner.removeAll()
    }

    private func finish(_ entry: Active, in scene: Scene) {
        switch entry.policy {
        case .complete:
            entry.clip.apply(at: entry.clip.duration, in: scene)
            entry.completion?()
        case .cancel:
            entry.clip.rewind(in: scene)
        }
    }

    public var debugString: String {
        guard !active.isEmpty else { return "interactions idle" }
        let lines = active.map {
            "  \($0.clip.label) @ \(fmt($0.time, decimals: 2))/\(fmt($0.clip.duration, decimals: 2))s"
        }
        return "interactions:\n" + lines.joined(separator: "\n")
    }
}
