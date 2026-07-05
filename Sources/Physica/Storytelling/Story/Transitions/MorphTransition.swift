// Content morph — TransformMatching the previous slide into this one.

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
import PhysicaFoundation

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
        insertedTargets = pairs.map(\.target).filter { !scene.contains($0) }
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
