// .shake(entity) — a quick damped horizontal wobble, the "no" feedback for a
// rejected drop. Like `.highlight`, it is a static `Animation` factory (so it
// resolves through the concrete `play(_: Animation...)` / `interact(_: Animation...)`
// overloads) rather than an entity method. Scrub-safe: the wobble is a pure
// function of clip-local time that is exactly zero at both ends, so the entity
// sits at its captured start position before the window and after it.

public extension Animation {
    /// Damped left-right shake of `target` (and any further animation targets),
    /// returning to the captured start each time: `scene.interact(.shake(token))`.
    static func shake(_ target: any Animatable, amplitude: Real = 0.18, cycles: Real = 3) -> Animation {
        let blueprint = ShakeBlueprint(amplitude: amplitude, cycles: cycles)
        return Animation(pairs: target.animationTargets.map {
            AnimationPair(target: $0, blueprint: blueprint)
        })
    }
}

struct ShakeBlueprint: AnimationBlueprint {
    let amplitude: Real
    let cycles: Real

    var debugLabel: String { "shake(amplitude: \(fmt(amplitude, decimals: 2)))" }
    var defaultDuration: Duration { .seconds(0.4) }

    func makeTrack(
        target: Entity, duration: TimeInterval, offset: TimeInterval, easing: Easing, in scene: Scene
    ) -> any AnimationTrackProtocol {
        ShakeTrack(
            target: target, amplitude: amplitude, cycles: cycles,
            duration: duration, offset: offset,
            label: "\(name(of: target)).\(debugLabel)"
        )
    }
}

@MainActor
final class ShakeTrack: AnimationTrackProtocol {
    let duration: TimeInterval
    let offset: TimeInterval
    let label: String
    private let target: Entity
    private let amplitude: Real
    private let cycles: Real

    private var startPosition: Position?

    init(
        target: Entity, amplitude: Real, cycles: Real,
        duration: TimeInterval, offset: TimeInterval, label: String
    ) {
        self.target = target
        self.amplitude = amplitude
        self.cycles = cycles
        self.duration = max(duration, 0)
        self.offset = max(offset, 0)
        self.label = label
    }

    func begin(in scene: Scene) {
        guard startPosition == nil else { return }
        startPosition = target.position
    }

    func apply(at clipTime: TimeInterval, in scene: Scene) {
        guard let start = startPosition else { return }
        let local = clipTime - offset
        // Zero offset outside the active window — exact at both endpoints, so a
        // shake leaves nothing behind no matter where playback lands.
        guard duration > 0, local > 0, local < duration else {
            target.position = start
            return
        }
        let t = Real(local / duration)
        let wobble = amplitude * Real.sin(2 * Real.pi * cycles * t) * (1 - t)
        target.position = Position(start.x + wobble, start.y, start.z)
    }

    func rewind(in scene: Scene) {
        if let start = startPosition {
            target.position = start
        }
    }
}
