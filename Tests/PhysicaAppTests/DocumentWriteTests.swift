// PhysicaDocument.write — the native facade that serializes a Document to a
// single self-contained HTML file. macOS-only (Foundation file I/O); the neutral
// serializer it wraps is covered by ArticleHTMLTests.

import Testing
import Foundation
import PhysicaApp

@Suite struct DocumentWriteTests {
    private func makeDoc() -> PhysicaDocument {
        PhysicaDocument("Rigid bodies") {
            Title("A rigid body", subtitle: "How Physica integrates it")
            Chapter("State", id: "state") {
                "The state is \\((q, p, L)\\)."
                math(type: .equation) { "\\dot q = \\partial H / \\partial p" }
            }
            Footer { "Physica" }
        }
    }

    @Test @MainActor func writesReadableHTMLFile() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("physica-document-write-test.html")
        try? FileManager.default.removeItem(at: url)

        let doc = makeDoc()
        try doc.write(to: url)

        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.hasPrefix("<!doctype html>"))
        #expect(text.contains("<title>Rigid bodies</title>"))
        #expect(text.contains("<h1>A rigid body</h1>"))
        #expect(text.contains("<h2 id=\"state\">"))
        #expect(text.contains("tex-mml-chtml.js"))
        // The file is exactly what html() produces.
        #expect(text == doc.html())

        try? FileManager.default.removeItem(at: url)
    }

    @Test @MainActor func overwritesExistingFile() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("physica-document-overwrite-test.html")
        try Data("stale".utf8).write(to: url)

        try makeDoc().write(to: url)
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(!text.contains("stale"))
        #expect(text.hasPrefix("<!doctype html>"))

        try? FileManager.default.removeItem(at: url)
    }
}
