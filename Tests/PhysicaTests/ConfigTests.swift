// Config host tests — the defaults singleton: scene creation picks up
// background/camera, `Text()` picks up textColor, fonts route through
// FontBook (defaultFont → fallback → `Font.default`), `custom(font:)`
// reglyphs, and `reset()` restores everything. Font-dependent tests parse a
// system TTF and skip quietly when none is available (CI without system
// fonts), like TTFTests.

import Testing
import Foundation
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

@Suite @MainActor struct ConfigTests {
    private let tolerance: Real = 1e-4

    @Test func sceneStartsFromConfigDefaults() {
        Config.reset()
        Config.background = .blackboard(tint: .white)
        Config.camera = .orthographicFit(extent: 24)
        defer { Config.reset() }

        let scene = Scene()
        #expect(scene.background == .blackboard(tint: .white))
        #expect(scene.camera.projection == .orthographicFit(extent: 24))

        // Per-scene assignment still overrides, without touching the default.
        scene.background = .color(.black)
        #expect(Config.background == .blackboard(tint: .white))
    }

    @Test func resetRestoresSceneDefaults() {
        Config.background = .blackboard(tint: .white)
        Config.camera = .perspective(fovYDegrees: 45)
        Config.mathJaxReady = true
        Config.reset()

        let scene = Scene()
        #expect(scene.background == .color(.background))
        #expect(scene.camera.projection == .orthographicFit(extent: 10))
        #expect(!Config.mathJaxReady)
    }

    @Test func textUsesConfigTextColor() {
        Config.reset()
        Config.textColor = .red
        defer { Config.reset() }

        let styled = Text("hi")
        #expect(styled.components[RenderStyleComponent.self]?.color == .red)
        // An explicit color still wins.
        let explicit = Text("hi", color: .blue)
        #expect(explicit.components[RenderStyleComponent.self]?.color == .blue)
    }

    @Test func defaultFontBacksBareTextEntity() throws {
        Config.reset()
        defer { Config.reset() }

        // Nothing registered: Font.default is the empty face — no glyphs, no trap.
        let degraded = TextEntity("Hi")
        #expect(degraded.textComponent.glyphs.isEmpty)
        #expect(degraded.name == "Hi")

        guard let font = loadSystemFont() else { return }
        Config.defaultFont(font)
        let entity = TextEntity("Hi")
        #expect(!entity.textComponent.glyphs.isEmpty)
        // The role factory resolves through the same fallback.
        let viaRole = Text("Hi", font: .title)
        #expect(!viaRole.textComponent.glyphs.isEmpty)
        #expect(abs(viaRole.textComponent.fontSize - 1.2) < tolerance)
    }

    @Test func customReglyphsWithAConcreteFace() throws {
        Config.reset()
        defer { Config.reset() }
        guard let font = loadSystemFont() else { return }

        // A degraded Text (no face registered) recovers via .custom(font:).
        let entity = Text("Hi")
        #expect(entity.textComponent.glyphs.isEmpty)
        entity.custom(font: font, size: 2)
        #expect(!entity.textComponent.glyphs.isEmpty)
        #expect(abs(entity.textComponent.fontSize - 2) < tolerance)
        #expect(
            abs((entity.components[RenderStyleComponent.self]?.strokeWidth ?? 0) - 0.024)
                < tolerance
        )
    }

    @Test func roleRegistrationIsVisibleToTheFacadeSkip() throws {
        Config.reset()
        defer { Config.reset() }
        #expect(!FontBook.hasRegistration(for: .math))
        guard let font = loadSystemFont() else { return }
        Config.font(font, for: .math, size: 0.9)
        #expect(FontBook.hasRegistration(for: .math))
        #expect(abs(FontBook.resolve(.math).size - 0.9) < tolerance)
    }
}
