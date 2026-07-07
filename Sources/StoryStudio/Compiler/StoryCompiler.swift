// StoryCompiler — lowers a `StoryDocument` into a fresh, scrubbable `Story`.
//
// This is the heart of the editor: because the Physica timeline is append-only,
// every edit produces a brand-new engine/scene/story built from scratch here
// (mirroring how `WaveStory.build` authors a story by hand). The compile is pure
// value → entity construction — cheap enough to run on every committed edit.
//
// `build` also returns the element-id → built-entity map so the editor can
// re-find the live entity for a document element after a rebuild (selection,
// drag, highlight). Phase 0 has no elements yet, so the map is empty.
//
// Platform-neutral: `Engine`/`Scene`/`Story` are all dependency-free core types,
// so this type-checks and unit-tests on the host with no GPU or DOM.

import Physica

@MainActor
enum StoryCompiler {
    /// The product of one compile: a self-contained engine/scene/story plus the
    /// `ElementDoc.id → Entity` map (empty until Phase 1 introduces elements).
    struct Build {
        let engine: Engine
        let scene: Scene
        let story: Story
        let entities: [Int: Entity]
    }

    /// Builds a fresh story from `document`. `font` gates text/labels and
    /// `mathSVG` (tex → MathJax SVG, resolved on the WASI side) gates math — both
    /// degrade gracefully (the runtime still narrates via captions).
    static func build(_ document: StoryDocument, font: Font?, mathSVG: [String: String] = [:]) -> Build {
        let engine = Engine()
        let scene = engine.makeScene(name: "studio") { _ in }
        let story = Story(scene: scene)
        story.background = .blackboard

        var entities: [Int: Entity] = [:]

        for slideDoc in document.slides {
            story.slide(slideDoc.title, transition: transition(slideDoc.transition)) { s in
                // Emit every slide's caption (even empty) so each slide's band
                // reflects exactly its own narration — captions are otherwise
                // sticky and a later empty slide would keep showing the prior one.
                story.caption(slideDoc.caption)

                // Elements first revealed by a `.write` step aren't pre-added —
                // that step introduces them; the rest are shown at slide start.
                let introducedByStep = Set(slideDoc.steps.filter { $0.verb == .write }.map { $0.elementID })

                var built: [Int: Entity] = [:]
                for element in slideDoc.elements {
                    guard let entity = ElementBuilder.build(element, font: font, mathSVG: mathSVG) else { continue }
                    built[element.id] = entity
                    entities[element.id] = entity
                    if !introducedByStep.contains(element.id) {
                        s.add(entity)
                    } else if let image = entity as? Image {
                        // A bitmap has no strokes to write: it pre-adds hidden
                        // and its `.write` step fades it in (the framework's
                        // image-reveal idiom, `scene.add`/`fade`).
                        image.components[RenderStyleComponent.self]?.opacity = 0
                        s.add(image)
                    }
                }

                // Lower steps in start order, inserting waits for the gaps so each
                // step lands on its own navigable beat.
                let steps = slideDoc.steps.sorted { $0.start < $1.start }
                var cursor: Double = 0
                for step in steps {
                    if step.start > cursor + 1e-6 {
                        s.wait(.seconds(step.start - cursor))
                        cursor = step.start
                    }
                    if step.verb == .wait {
                        s.wait(.seconds(step.duration))
                        cursor += step.duration
                        continue
                    }
                    guard let entity = built[step.elementID],
                          let anim = animation(step.verb, for: entity) else { continue }
                    s.play(anim, for: .seconds(step.duration))
                    cursor += step.duration
                }

                // Empty slides still need a non-zero span so multi-slide
                // navigation lands on separate beats.
                if steps.isEmpty { s.wait() }
            }
        }

        return Build(engine: engine, scene: scene, story: story, entities: entities)
    }

    /// Maps a step verb to a Physica animation on the built entity. `.write`
    /// reveals (text writes, shapes draw); `nil` for verbs handled elsewhere.
    private static func animation(_ verb: VerbSpec, for entity: Entity) -> Animation? {
        switch verb {
        case .write:
            if let text = entity as? TextEntity { return .write(text) }
            if let path = entity as? PathEntity { return .draw(path) }
            if entity is Image { return entity.fade(to: 1) }   // pre-added hidden above
            return nil
        case let .fade(to):
            return entity.fade(to: to)
        case let .scaleTo(factor):
            return entity.scale(to: factor)
        case let .color(hex):
            return entity.color(Color(hex: hex))
        case .wait:
            return nil
        }
    }

    private static func transition(_ spec: TransitionSpec) -> SlideTransition {
        switch spec {
        case .none: return .none
        case .fade: return .fade()
        case .pushLeft: return .push(from: .left)
        case .pushRight: return .push(from: .right)
        case .pushUp: return .push(from: .top)
        case .pushDown: return .push(from: .bottom)
        case .zoom: return .zoom(from: 14)
        case .morph: return .morph()
        }
    }
}
