import Testing
@testable import Physica

@Suite @MainActor struct SwipeTests {
    @Test func recognizesHorizontalSwipes() {
        var r = SwipeRecognizer(threshold: 1.0)
        r.begin(at: Position(0, 0, 0))
        r.move(to: Position(2, 0.1, 0))
        #expect(r.end() == .right)

        r.begin(at: Position(0, 0, 0))
        r.move(to: Position(-2, 0, 0))
        #expect(r.end() == .left)
    }

    @Test func recognizesVerticalSwipes() {
        var r = SwipeRecognizer(threshold: 1.0)
        r.begin(at: Position(0, 0, 0))
        r.move(to: Position(0.1, 2, 0))   // world y up → swipe up
        #expect(r.end() == .up)

        r.begin(at: Position(0, 0, 0))
        r.move(to: Position(0, -2, 0))
        #expect(r.end() == .down)
    }

    @Test func belowThresholdIsNil() {
        var r = SwipeRecognizer(threshold: 1.0)
        r.begin(at: Position(0, 0, 0))
        r.move(to: Position(0.4, 0.3, 0))   // a tap-sized nudge
        #expect(r.end() == nil)
    }

    @Test func dominantAxisWins() {
        var r = SwipeRecognizer(threshold: 1.0)
        r.begin(at: Position(0, 0, 0))
        r.move(to: Position(3, 1.2, 0))     // mostly horizontal
        #expect(r.end() == .right)
    }

    @Test func cancelClearsGesture() {
        var r = SwipeRecognizer(threshold: 1.0)
        r.begin(at: Position(0, 0, 0))
        r.move(to: Position(3, 0, 0))
        r.cancel()
        #expect(!r.isTracking)
        #expect(r.end() == nil)             // a cancelled gesture resolves to nothing
    }

    @Test func endWithoutBeginIsNil() {
        var r = SwipeRecognizer(threshold: 1.0)
        #expect(r.end() == nil)
    }

    @Test func endResetsTracking() {
        var r = SwipeRecognizer(threshold: 1.0)
        r.begin(at: Position(0, 0, 0))
        r.move(to: Position(2, 0, 0))
        #expect(r.isTracking)
        _ = r.end()
        #expect(!r.isTracking)
    }
}
