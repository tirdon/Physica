// Counter + blend tests — the tracking formatters (pure), the reglyphing
// TrackingTextEntity and its `count(to:)` animation, and additive blending
// (overlapping same-property animations summing, scrub-safe).

import Testing
@testable import PhysicaFoundation
@testable import PhysicaAlgebra
@testable import PhysicaTypesetting
@testable import PhysicaKernel
@testable import PhysicaCharts
@testable import PhysicaPhysics
@testable import PhysicaEquationGame

@Suite @MainActor struct CounterBlendTests {
    private let tolerance: Real = 1e-4

    // MARK: Trackings (pure formatters)

    @Test func trackingsFormatValues() {
        #expect(IntegerTracking().text(for: 3.4) == "3")
        #expect(IntegerTracking().text(for: 99.6) == "100")
        #expect(DecimalTracking(decimals: 2).text(for: 1.5) == "1.50")
        let ramp = UnicodeTracking("AB")
        #expect(ramp.text(for: -1) == "A")
        #expect(ramp.text(for: 0.4) == "A")
        #expect(ramp.text(for: 1) == "B")
        #expect(ramp.text(for: 7) == "B")
        #expect(UnicodeTracking("").text(for: 3) == "")
    }

    // MARK: TrackingTextEntity

    @Test func counterCountsUpAndScrubsBack() {
        let scene = Scene()
        let counter = TrackingTextEntity(0, font: nil)   // fontless: name mirrors the text
        scene.add(counter)
        scene.play(counter.count(to: 10), for: 1.s, easing: .linear)

        scene.seek(to: 1)
        #expect(abs(counter.value - 10) < tolerance)
        #expect(counter.name == "10")
        scene.seek(to: 0.5)
        #expect(abs(counter.value - 5) < 0.6)            // linear midpoint
        scene.seek(to: 0)
        #expect(abs(counter.value) < tolerance)
        #expect(counter.name == "0")
    }

    @Test func counterReformatsThroughItsTracking() {
        let counter = TrackingTextEntity(0, tracking: DecimalTracking(decimals: 1), font: nil)
        counter.value = 2.36
        #expect(counter.name == "2.4")
    }

    // MARK: Additive blend

    @Test func additiveShiftsSumAndScrubBack() {
        let scene = Scene()
        let dot = Circle(radius: 0.2)
        scene.add(dot)
        scene.play(
            group: dot.shift(Position(2, 0, 0), blend: .additive),
            dot.shift(Position(0, 0.4, 0), blend: .additive)
        )

        scene.seek(to: 1)
        #expect(abs(dot.position.x - 2) < tolerance)
        #expect(abs(dot.position.y - 0.4) < tolerance)
        scene.seek(to: 0.5)
        #expect(dot.position.x > 0 && dot.position.x < 2)
        #expect(dot.position.y > 0 && dot.position.y < 0.4)
        scene.seek(to: 0)
        #expect(abs(dot.position.x) < tolerance)
        #expect(abs(dot.position.y) < tolerance)
    }

    @Test func additiveReplaceFallbackMatchesPlainShift() {
        let scene = Scene()
        let dot = Circle(radius: 0.2)
        scene.add(dot)
        scene.play(dot.shift(Position(1, 0, 0), blend: .replace), for: 1.s)
        scene.seek(to: 1)
        #expect(abs(dot.position.x - 1) < tolerance)
    }

    @Test func additiveRotateComposes() {
        let scene = Scene()
        let box = Rectangle(width: 1, height: 0.5)
        scene.add(box)
        scene.play(box.rotate(by: .pi / 2, blend: .additive), for: 1.s)

        scene.seek(to: 1)
        // A quarter turn about z maps +x to +y.
        let mapped = box.orientation.rotate(Position(1, 0, 0))
        #expect(abs(mapped.x) < 1e-3)
        #expect(abs(mapped.y - 1) < 1e-3)
        scene.seek(to: 0)
        let restored = box.orientation.rotate(Position(1, 0, 0))
        #expect(abs(restored.x - 1) < 1e-3)
    }
}
