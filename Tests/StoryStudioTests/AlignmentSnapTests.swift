import Testing
import Physica
@testable import StoryStudio

@Suite struct AlignmentSnapTests {
    // A default-fit 10 × 6.25 frame centred on the origin.
    let frame = SnapBox(minX: -5, minY: -3.125, maxX: 5, maxY: 3.125)

    @Test func snapsCenterToScreenCenterX() {
        // centreX = 0.05, within 0.2 of the screen centre (x = 0) → nudge left 0.05.
        // Parked well off y = 0 so only the X axis snaps (one guide).
        let moving = SnapBox(minX: -0.95, minY: 0.3, maxX: 1.05, maxY: 1.3)
        let out = AlignmentSnap.resolve(moving: moving, others: [],
                                        screenCenter: (0, 0), frame: frame, threshold: 0.2)
        #expect(abs(out.dx - (-0.05)) < 1e-6)
        #expect(out.dy == 0)
        #expect(out.guides.count == 1)
        let g = out.guides[0]
        #expect(g.axis == .vertical)
        #expect(g.kind == .screenCenter)
        #expect(abs(g.position) < 1e-6)
        // a screen-centre guide spans the full frame height
        #expect(abs(g.start - frame.minY) < 1e-6)
        #expect(abs(g.end - frame.maxY) < 1e-6)
    }

    @Test func noSnapBeyondThreshold() {
        let moving = SnapBox(minX: 2, minY: 2, maxX: 3, maxY: 3)
        let out = AlignmentSnap.resolve(moving: moving, others: [],
                                        screenCenter: (0, 0), frame: frame, threshold: 0.2)
        #expect(out == .none)
    }

    @Test func snapsLeftEdgeToOtherElementLeft() {
        let other = SnapBox(minX: 1.0, minY: -1, maxX: 2.0, maxY: 0)
        // left edge at 1.08 → snaps to 1.0 (dx -0.08); centre/right are farther.
        // Screen centre parked far away so only the element line is in range.
        let moving = SnapBox(minX: 1.08, minY: 1, maxX: 1.58, maxY: 2)
        let out = AlignmentSnap.resolve(moving: moving, others: [other],
                                        screenCenter: (-10, -10), frame: frame, threshold: 0.2)
        #expect(abs(out.dx - (-0.08)) < 1e-6)
        #expect(out.dy == 0)
        #expect(out.guides.count == 1)
        let g = out.guides[0]
        #expect(g.axis == .vertical)
        #expect(g.kind == .element)
        #expect(abs(g.position - 1.0) < 1e-6)
        // an element guide spans the union of the two boxes' perpendicular extent
        #expect(abs(g.start - (-1)) < 1e-6)
        #expect(abs(g.end - 2) < 1e-6)
    }

    @Test func snapsBothAxesAtOnce() {
        // box centred at (0.05, -0.05) → snaps to the screen centre on both axes.
        let moving = SnapBox(minX: -0.95, minY: -1.05, maxX: 1.05, maxY: 0.95)
        let out = AlignmentSnap.resolve(moving: moving, others: [],
                                        screenCenter: (0, 0), frame: frame, threshold: 0.2)
        #expect(abs(out.dx - (-0.05)) < 1e-6)
        #expect(abs(out.dy - 0.05) < 1e-6)
        #expect(out.guides.count == 2)
        #expect(out.guides.contains { $0.axis == .vertical })
        #expect(out.guides.contains { $0.axis == .horizontal })
    }

    @Test func prefersNearestAnchor() {
        // Only centre-to-centre is in range: the dragged box's edges (±0.2 around
        // centreX 0.05) sit > 0.1 from every line, so the −0.05 centre gap wins.
        let other = SnapBox(minX: -1, minY: -1, maxX: 1, maxY: 1)          // centreX 0
        let moving = SnapBox(minX: -0.15, minY: 2, maxX: 0.25, maxY: 3)    // centreX 0.05
        let out = AlignmentSnap.resolve(moving: moving, others: [other],
                                        screenCenter: (-10, -10), frame: frame, threshold: 0.1)
        #expect(abs(out.dx - (-0.05)) < 1e-6)
        #expect(out.guides.count == 1)
        #expect(out.guides[0].kind == .element)
        #expect(abs(out.guides[0].position - 0) < 1e-6)   // aligned to the other box's centreX
    }
}
