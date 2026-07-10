// ArticleHTML — the static Document→HTML serializer (PhysicaArticle). Locks the
// self-contained page shape, HTML escaping (with TeX kept verbatim for MathJax),
// inline markup, chapter anchors, and the light/dark theme split. Neutral, so it
// runs on the host via the umbrella (`import Physica`), same as ArticleThemeTests.

import Testing
import Physica

@Suite struct ArticleHTMLTests {
    private func sample(background: Color = .documentLight) -> Document {
        Document("My Title", background: background) {
            Title(
                eyebrow: "Eyebrow",
                "Head <line>",
                subtitle: "Sub",
                byline: Byline(avatar: "PH", name: "Name", meta: "meta"),
                abstract: "Abs with *em* and \\(p = mv\\).",
                stats: [Stat(value: "1/240 s", label: "step")]
            )
            Chapter("First & Best", id: "one") {
                "A paragraph with **bold** and `code`."
                math(type: .equation, tag: "e1") { "a = b" }
                math(type: .display) { "x^2" }
                notation { Def("\\(H\\)", "Hamiltonian") }
                procedure(name: "Proc 1", title: "Do it", input: "x", output: "y") {
                    Step("step one", note: "half")
                    Return("done")
                }
                table(columns: 2) { formula("\\Delta t"); "fixed" }
                figure("figs/rig.png", caption: "Cap")
            }
            Footer { "line 1"; "line 2" }
        }
    }

    @Test func rendersSelfContainedDocument() {
        let html = ArticleHTML.render(sample())
        #expect(html.hasPrefix("<!doctype html>"))
        #expect(html.contains("<title>My Title</title>"))
        #expect(html.contains("id=\"\(ArticleStyle.elementID)\""))   // stylesheet inlined
        #expect(html.contains("tex-mml-chtml.js"))                    // MathJax CDN loader
        #expect(html.contains("<article class=\"paper\">"))
        #expect(html.hasSuffix("</html>\n"))
    }

    @Test func escapesTextButKeepsTeX() {
        let html = ArticleHTML.render(sample())
        #expect(html.contains("<h1>Head &lt;line&gt;</h1>"))     // angle brackets escaped
        #expect(html.contains("First &amp; Best"))                // ampersand escaped
        #expect(html.contains("$$a = b\\tag{1}$$"))               // equation auto-numbered, TeX intact
        #expect(!html.contains("<line>"))                          // no raw markup injection
    }

    @Test func inlineMarkupBecomesTags() {
        let html = ArticleHTML.render(sample())
        #expect(html.contains("<strong>bold</strong>"))
        #expect(html.contains("<code>code</code>"))
        #expect(html.contains("<em>em</em>"))
        #expect(html.contains("\\(p = mv\\)"))                     // inline math survives verbatim
    }

    @Test func chapterAnchorsMatchTopbarLinks() {
        let html = ArticleHTML.render(sample())
        #expect(html.contains("<h2 id=\"one\">"))
        #expect(html.contains("href=\"#one\""))
        #expect(html.contains("§1"))
    }

    @Test func procedureFigureAndTableStructure() {
        let html = ArticleHTML.render(sample())
        #expect(html.contains("class=\"procedure\""))
        #expect(html.contains("<li class=\"ret\">return "))        // return line
        #expect(html.contains("class=\"dcell dcell-math\""))       // math table cell
        #expect(html.contains("<figure class=\"figure\">"))
        #expect(html.contains("src=\"figs/rig.png\""))
        #expect(!html.contains("crossorigin"))                     // standalone figures load off file://
    }

    @Test func themeOverrideOnlyForNonLightBackground() {
        #expect(!ArticleHTML.render(sample(background: .documentLight)).contains(ArticleStyle.themeElementID))
        #expect(ArticleHTML.render(sample(background: .documentDark)).contains(ArticleStyle.themeElementID))
    }
}
