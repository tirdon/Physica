// DocumentDeck — the native realization of a `presentation {}` block. The web
// edition boots each deck as a live WebGPU story (`ArticleStoryDeck`); natively
// there is no browser canvas, so this rebuilds the same story on the *engine*
// (Engine / Scene / Story / StoryPlayer) and presents it one of two ways:
//
//   • `PhysicaDocument.run()`  floats a real Metal view over the deck's slot in
//     the article (see `DeckOverlayController`, which drives a `StoryPlayer`).
//   • `PhysicaDocument.write()` bakes the deck to a short H.264 movie and embeds
//     it in the self-contained `.html` as a base64 `<video>` (`videoMarkup`).
//
// Both start from the same `buildStory` — the native mirror of
// `ArticleStoryDeck.boot`'s slide loop — so the windowed deck and the written
// video show the same content.

import PhysicaFoundation
import PhysicaTypesetting
import PhysicaKernel
import PhysicaArticle

#if os(macOS)
import CoreGraphics
import Foundation

@MainActor
enum DocumentDeck {
    /// Deck stage palette, matching `ArticleStoryDeck` (chalk text, accent green).
    static let chalk = Color(hex: 0xF2F2EC)
    static let accent = Color(hex: 0x4CC878)

    /// Every `presentation {}` deck in the document, in reading order — the same
    /// order `ArticleHTML`'s `deckOrdinal` counts, so the returned index lines up
    /// with the `deckOverrides` key the caller passes back.
    static func decks(in document: Document) -> [[DeckSlide]] {
        var result: [[DeckSlide]] = []
        for section in document.sections {
            guard case let .chapter(chapter) = section else { continue }
            for block in chapter.blocks {
                if case let .presentation(slides) = block { result.append(slides) }
            }
        }
        return result
    }

    /// Builds a `Story` from a deck's slides on a fresh scene of `engine` — the
    /// native mirror of `ArticleStoryDeck.boot`'s slide loop. Each slide's prose
    /// narrates as the caption; its visual is the author's `animate` closure, or
    /// the default title + accent underline when the slide is prose-only.
    static func buildStory(_ slides: [DeckSlide], font: Font?, engine: Engine) -> Story {
        let scene = engine.makeScene(name: "article-deck") { _ in }
        let story = Story(scene: scene)
        story.background = .blackboard
        for slide in slides {
            story.slide(slide.title) { s in
                story.caption(captionText(slide))
                if let animate = slide.animate {
                    animate(s)
                    return
                }
                if let font {
                    let heading = TextEntity(slide.title, font: font, fontSize: 0.72, color: chalk)
                    heading.position = Position(0, 0.55, 0)
                    s.play(.write(heading), for: 0.9.s)
                }
                let underline = Line(
                    start: Position(-2.4, -0.35, 0), end: Position(2.4, -0.35, 0),
                    width: 0.05, color: accent
                )
                s.play(.draw(underline), for: 0.6.s)
            }
        }
        return story
    }

    /// A slide's plain narration for the caption band (mirrors
    /// `ArticleStoryDeck.captionText`): its paragraphs, headings, and inline-math
    /// blocks re-delimited for MathJax, joined.
    static func captionText(_ slide: DeckSlide) -> String {
        var parts: [String] = []
        for block in slide.blocks {
            switch block {
            case let .paragraph(text): parts.append(text)
            case .headline(let text), .subheadline(let text): parts.append(text)
            case let .math(_, _, tex): parts.append("\\(" + tex + "\\)")
            default: break
            }
        }
        return parts.joined(separator: " ")
    }

    /// Renders a deck to a short H.264 movie and returns a self-contained
    /// `<figure><video>…</figure>` with the movie base64-embedded as a `data:`
    /// URI — the static-file counterpart of the live overlay. The whole timeline
    /// (every slide, built then cleared then the next) plays linearly. Returns nil
    /// if Metal is unavailable or the export fails; the caller then falls back to
    /// the static outline.
    static func videoMarkup(
        for slides: [DeckSlide], font: Font?, size: CGSize, fps: Int
    ) -> String? {
        let engine = Engine()
        let story = buildStory(slides, font: font, engine: engine)
        let scene = story.scene
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("physica-deck-\(scene.id).mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            try SceneExporter.write(
                scene: scene, to: url, size: size,
                duration: scene.timeline.duration, fps: fps, time: 0
            )
        } catch {
            print("Physica: deck video export failed — \(error)")
            return nil
        }
        guard let data = try? Data(contentsOf: url) else { return nil }

        let plural = slides.count == 1 ? "" : "s"
        var html = "<figure class=\"figure deck-video\">"
        html += "<video controls loop muted playsinline preload=\"metadata\""
        html += " style=\"width:100%;display:block;border-radius:12px\">"
        html += "<source src=\"data:video/mp4;base64,\(data.base64EncodedString())\" type=\"video/mp4\">"
        html += "</video>"
        html += "<figcaption>▷ Interactive presentation — \(slides.count) slide\(plural)"
        html += " (rendered to video)</figcaption></figure>"
        return html
    }
}
#endif
