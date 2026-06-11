import Testing
@testable import Physica

@Suite @MainActor
struct SVGPathTests {
    @Test func absoluteMoveLineClose() throws {
        let path = try Path.svg("M 10 20 L 30 40 Z")
        #expect(path.contours.count == 1)
        let contour = path.contours[0]
        #expect(contour.start == SIMD2(10, 20))
        #expect(contour.segments == [.line(to: SIMD2(30, 40))])
        #expect(contour.isClosed)
    }

    @Test func relativeWithImplicitLineRepeats() throws {
        // After m, bare coordinate pairs repeat as relative linetos.
        let path = try Path.svg("m 1 2 3 4 5 6")
        let contour = path.contours[0]
        #expect(contour.start == SIMD2(1, 2))
        #expect(contour.segments == [.line(to: SIMD2(4, 6)), .line(to: SIMD2(9, 12))])
        #expect(!contour.isClosed)
    }

    @Test func horizontalAndVertical() throws {
        let path = try Path.svg("M0 0 H10 V5 h-2 v-1")
        #expect(path.contours[0].segments == [
            .line(to: SIMD2(10, 0)), .line(to: SIMD2(10, 5)),
            .line(to: SIMD2(8, 5)), .line(to: SIMD2(8, 4)),
        ])
    }

    @Test func smoothCubicReflectsControl() throws {
        let path = try Path.svg("M0 0 C 0 10 10 10 10 0 S 20 -10 20 0")
        guard case .curve(let control1, _, let to) = path.contours[0].segments[1] else {
            Issue.record("expected a cubic for S")
            return
        }
        // Reflection of (10, 10) about the current point (10, 0).
        #expect(control1 == SIMD2(10, -10))
        #expect(to == SIMD2(20, 0))
    }

    @Test func smoothQuadReflectsControl() throws {
        let path = try Path.svg("M0 0 Q 5 10 10 0 T 20 0")
        guard case .quadCurve(let control, let to) = path.contours[0].segments[1] else {
            Issue.record("expected a quad for T")
            return
        }
        #expect(control == SIMD2(15, -10))
        #expect(to == SIMD2(20, 0))
    }

    @Test func negativeNumbersNeedNoSeparators() throws {
        // "1-2" is two numbers; "-1.5.5" is -1.5 then .5 (TTF-style packing).
        let path = try Path.svg("M1-2l-1.5.5")
        let contour = path.contours[0]
        #expect(contour.start == SIMD2(1, -2))
        #expect(contour.segments.count == 1)
        guard case .line(let to) = contour.segments[0] else {
            Issue.record("expected a line")
            return
        }
        #expect(approx(to.x, -0.5, tolerance: 1e-6))
        #expect(approx(to.y, -1.5, tolerance: 1e-6))
    }

    @Test func exponents() throws {
        let path = try Path.svg("M1e1 2E-1 L1.5e0 0")
        let contour = path.contours[0]
        #expect(approx(contour.start.x, 10))
        #expect(approx(contour.start.y, 0.2))
    }

    @Test func multipleSubpaths() throws {
        let path = try Path.svg("M0 0 L1 0 M5 5 L6 5 Z")
        #expect(path.contours.count == 2)
        #expect(!path.contours[0].isClosed)
        #expect(path.contours[1].isClosed)
        #expect(path.contours[1].start == SIMD2(5, 5))
    }

    @Test func arcLowersToCubicsOnTheCircle() throws {
        // Half circle of radius 5 from (0,0) to (10,0): center must be (5,0),
        // every flattened point at distance 5 from it, endpoints exact.
        let path = try Path.svg("M 0 0 A 5 5 0 0 1 10 0")
        let points = path.flattened()[0].points
        #expect(approx(points.first!.x, 0) && approx(points.first!.y, 0))
        #expect(approx(points.last!.x, 10) && approx(points.last!.y, 0))
        for point in points {
            #expect(approx((point - SIMD2(5, 0)).distance(), 5, tolerance: 0.01))
        }
        // sweep=1 keeps the arc on the positive-rotation side in SVG terms:
        // all midpoints below the chord (negative y).
        let mid = points[points.count / 2]
        #expect(mid.y < -4.9)
    }

    @Test func arcDegeneratesToLineWhenRadiusIsZero() throws {
        let path = try Path.svg("M0 0 A 0 5 0 0 1 10 0")
        #expect(path.contours[0].segments == [.line(to: SIMD2(10, 0))])
    }

    @Test func drawingWithoutMoveToThrows() {
        #expect(throws: SVGPathError.missingMoveTo) {
            try Path.svg("L 10 0")
        }
    }

    @Test func numbersAfterCloseThrow() {
        #expect(throws: SVGPathError.self) {
            try Path.svg("M0 0 L1 1 Z 5 5")
        }
    }
}
