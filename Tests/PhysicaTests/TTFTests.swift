import Foundation
import Testing
@testable import PhysicaFoundation
@testable import PhysicaAlgebra
@testable import PhysicaTypesetting
@testable import PhysicaKernel
@testable import PhysicaCharts
@testable import PhysicaPhysics
@testable import PhysicaEquationGame

private let systemFontCandidates = [
    "/System/Library/Fonts/Supplemental/Arial.ttf",
    "/System/Library/Fonts/Supplemental/Tahoma.ttf",
    "/System/Library/Fonts/Supplemental/Trebuchet MS.ttf",
]

private func loadSystemFont() -> Font? {
    for path in systemFontCandidates {
        guard FileManager.default.fileExists(atPath: path),
              let data = FileManager.default.contents(atPath: path) else { continue }
        if let font = try? Font(data: [UInt8](data)) {
            return font
        }
    }
    return nil
}

@Suite struct TTFTests {
    @Test func parseSystemFont() throws {
        guard let font = loadSystemFont() else {
            // No glyf-based system font available — environment-dependent, skip.
            return
        }
        #expect(font.unitsPerEm > 0)
        #expect(font.glyphCount > 100)
        #expect(font.ascender > 0)
        #expect(font.descender < 0)
    }

    @Test func glyphOutlines() throws {
        guard let font = loadSystemFont() else { return }

        let upperA = try #require(font.glyph(for: "A"))
        #expect(upperA.path.contours.count == 2)  // outline + counter
        #expect(upperA.advance > 0.3 && upperA.advance < 1)

        let upperI = try #require(font.glyph(for: "I"))
        #expect(upperI.path.contours.count >= 1)
        #expect(upperI.advance < upperA.advance)  // proportional font

        let lowerO = try #require(font.glyph(for: "o"))
        #expect(lowerO.path.contours.count == 2)

        // Em-normalized coordinates stay in sane bounds.
        let bounds = upperA.path.bounds
        #expect(bounds.size.x > 0.2 && bounds.size.x < 1.2)
        #expect(bounds.size.y > 0.3 && bounds.size.y < 1.2)
        #expect(bounds.min.y > -0.4)
    }

    @Test func cmapDistinguishesCharacters() throws {
        guard let font = loadSystemFont() else { return }
        let a = font.glyphIndex(for: "A")
        let b = font.glyphIndex(for: "B")
        #expect(a != nil && b != nil && a != b)
        #expect(font.glyphIndex(for: "\u{FFFF}") == nil || font.glyphIndex(for: "\u{FFFF}") != a)
    }

    @Test func spaceHasAdvanceButNoOutline() throws {
        guard let font = loadSystemFont() else { return }
        guard let space = font.glyph(for: " ") else { return }
        #expect(space.advance > 0.1)
        #expect(space.path.isEmpty)
    }

    @Test func malformedDataThrows() {
        #expect(throws: FontError.self) {
            _ = try Font(data: [0, 1, 2, 3, 4, 5])
        }
    }
}
