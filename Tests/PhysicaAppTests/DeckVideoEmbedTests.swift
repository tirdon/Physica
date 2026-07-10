// PhysicaDocument.write embeds each `presentation {}` deck as a self-contained
// base64 <video> (rendered headlessly via SceneExporter), instead of the static
// outline. The overlay path (run()) needs a window; this locks the file path,
// which is the one an author actually ships.

import Testing
import Foundation
import CoreGraphics
import Metal
import PhysicaKernel
import PhysicaApp

@Suite struct DeckVideoEmbedTests {
    @Test @MainActor func writeEmbedsDeckAsVideo() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { return }  // no Metal → skip

        let doc = PhysicaDocument("Deck") {
            Chapter("Show", id: "show") {
                "Some prose before the deck."
                presentation {
                    slide("One", caption: "The first slide.") { s in
                        let dot = Circle(radius: 0.5, color: .red)
                        s.play(.draw(dot), for: 0.3.s)
                    }
                }
            }
        }

        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("physica-deck-video-test.html")
        try? FileManager.default.removeItem(at: url)
        defer { try? FileManager.default.removeItem(at: url) }

        try doc.write(to: url, deckSize: CGSize(width: 160, height: 90), deckFPS: 10)
        let html = try String(contentsOf: url, encoding: .utf8)

        #expect(html.contains("<video"))
        #expect(html.contains("data:video/mp4;base64,"))
        #expect(html.contains("rendered to video"))
        // The live-deck video replaces the "needs the web edition" static outline.
        #expect(!html.contains("needs the web edition"))
    }
}
