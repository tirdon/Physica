// Document background themes — the `Color.documentLight`/`.documentDark`
// constants, the `Document(background:)` carry, and the `:root` override
// `ArticleStyle.theme(background:)` generates for the article stylesheet.
// ArticleStyle/ArticleDSL are the platform-neutral half of PhysicaWeb, so this
// runs on the host via the umbrella (`import Physica`).

import Testing
import Physica

@Suite struct ArticleThemeTests {
    @Test func namedDocumentColors() {
        #expect(Color.documentLight == Color(hex: 0xFAF7F2))
        #expect(Color.documentDark == Color(hex: 0x16161C))
        // The dark paper deliberately matches the scene default.
        #expect(Color.documentDark == Color.background)
    }

    @Test func documentCarriesItsBackground() {
        let stock = Document { Chapter("c") { "p" } }
        #expect(stock.background == .documentLight)
        let dark = Document(background: .documentDark) { Chapter("c") { "p" } }
        #expect(dark.background == .documentDark)
    }

    @Test func darkThemeDerivesLightInkOnTheGivenPaper() {
        let css = ArticleStyle.theme(background: .documentDark)
        #expect(css.contains("--paper:rgb(22,22,28)"))       // 0x16161C exactly
        #expect(css.contains("--text:#E9E7E1"))              // light ink
        #expect(css.contains("--veil:rgba(22,22,28,.92)"))   // topbar backdrop
        #expect(!css.contains("--card:#FFFFFF"))             // no white stat cards
    }

    @Test func lightThemeKeepsTheStockInk() {
        let css = ArticleStyle.theme(background: .documentLight)
        #expect(css.contains("--paper:rgb(250,247,242)"))
        #expect(css.contains("--text:#2A2825"))
        #expect(css.contains("--card:#FFFFFF"))
    }

    @Test func luminancePicksThePalette() {
        // A custom dark color (not the named one) still gets the dark ink…
        let navy = ArticleStyle.theme(background: Color(hex: 0x0D1117))
        #expect(navy.contains("--text:#E9E7E1"))
        // …and a custom light one keeps the dark ink.
        let cream = ArticleStyle.theme(background: Color(hex: 0xFFFDF7))
        #expect(cream.contains("--text:#2A2825"))
    }
}
