// The `figure` article block — the DSL carry and the stylesheet rules. The
// DOM builder itself is WASI-only (verified via the wasm build + headless
// Chrome); what the host locks in is the value model and the theme-variable
// styling, same split as ArticleThemeTests.

import Testing
import Physica

@Suite struct ArticleFigureTests {
    @Test func figureBuildsItsBlock() {
        let doc = Document {
            Chapter("Setup") {
                "Intro."
                figure("figures/rig.png", caption: "The rig, mid-swing.")
            }
        }
        guard case let .chapter(chapter) = doc.sections[0] else {
            Issue.record("expected a chapter"); return
        }
        #expect(chapter.blocks.count == 2)
        guard case let .figure(spec) = chapter.blocks[1] else {
            Issue.record("expected a figure block"); return
        }
        #expect(spec.source == "figures/rig.png")
        #expect(spec.caption == "The rig, mid-swing.")
        #expect(spec.alt == nil)   // the DOM falls back to the caption
    }

    @Test func stylesheetStylesTheFigureWithThemeVariables() {
        #expect(ArticleStyle.css.contains(".figure img"))
        #expect(ArticleStyle.css.contains(".figure figcaption"))
        // The rules lean on the palette vars, so `.documentDark` (which only
        // overrides :root variables) restyles figures with no extra CSS.
        let start = ArticleStyle.css.range(of: ".figure{")!.lowerBound
        let end = ArticleStyle.css.range(of: "presentation deck")!.lowerBound
        let rules = ArticleStyle.css[start..<end]
        #expect(rules.contains("var(--rule)"))
        #expect(rules.contains("var(--text-3)"))
    }
}
