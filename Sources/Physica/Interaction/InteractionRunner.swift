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
        let completion: (@MainActor () -> Void)?
    }

    private var active: [Active] = []
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
        completion: (@MainActor () -> Void)? = nil
    ) -> Handle {
        let handle = Handle(id: nextHandleID)
        nextHandleID += 1
        clip.begin(in: scene)
        if clip.duration <= 0 {
            clip.apply(at: 0, in: scene)
            completion?()
            return handle
        }
        clip.apply(at: 0, in: scene)
        active.append(Active(handle: handle, clip: clip, policy: policy, time: 0, completion: completion))
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

    /// Resolve everything in flight — the story player calls this on slide
    /// changes so no token strands mid-air.
    public func interruptAll(in scene: Scene) {
        let entries = active
        active.removeAll()
        for entry in entries {
            finish(entry, in: scene)
        }
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
