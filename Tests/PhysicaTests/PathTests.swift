import Testing
@testable import Physica

@Suite @MainActor
struct PathTests {
    @Test func circleFlattening() {
        let circle = Path.circle(radius: 1)
        let contours = circle.flattened()
        #expect(contours.count == 1)
        #expect(contours[0].isClosed)
        #expect(contours[0].points.count == 48)  // 4 cubics × 12, closing point dropped

        // Every flattened point sits on the circle within the Bézier error.
        for point in contours[0].points {
            #expect(approx(point.distance(), 1, tolerance: 5e-3))
        }
        #expect(approx(contours[0].totalLength, 2 * .pi, tolerance: 2e-2))
    }

    @Test func rectGeometry() {
        let rect = Path.rect(width: 4, height: 2)
        let bounds = rect.bounds
        #expect(approx(bounds.min, Position(-2, -1, 0)))
        #expect(approx(bounds.max, Position(2, 1, 0)))
        #expect(rect.debugString == "path[3c]")  // 3 explicit segments + implicit close
    }

    @Test func arcEndpoints() {
        let arc = Path.arc(center: .zero, radius: 2, startAngle: 0, endAngle: .pi)
        let points = arc.flattened()[0].points
        #expect(approx(points.first!.x, 2, tolerance: 1e-3))
        #expect(approx(points.first!.y, 0, tolerance: 1e-3))
        #expect(approx(points.last!.x, -2, tolerance: 1e-3))
        #expect(approx(points.last!.y, 0, tolerance: 1e-3))
    }

    @Test func resampling() {
        let square = Path.rect(width: 2, height: 2).flattened()[0]
        let resampled = square.resampled(count: 16)
        #expect(resampled.points.count == 16)
        #expect(approx(resampled.totalLength, square.totalLength, tolerance: 0.2))

        let open = Path.line(from: .zero, to: SIMD2(10, 0)).flattened()[0]
        let openResampled = open.resampled(count: 5)
        #expect(approx(openResampled.points.last!.x, 10))  // open ends stay pinned
        #expect(approx(openResampled.points[1].x, 2.5))
    }

    @Test func lineEntityRebuildsOnEndpointChange() {
        let line = Line(start: .origin, end: Position(0, -4, 0))
        #expect(approx(line.localBounds.size.y, 4))
        line.end = Position(3, 0, 0)
        #expect(approx(line.localBounds.size.x, 3))
        #expect(approx(line.localBounds.size.y, 0, tolerance: 1e-3))
    }

    @Test func shapeDefaults() {
        let circle = Circle()
        #expect(approx(circle.localBounds.size.x, 1))     // radius 0.5
        #expect(circle.style.isFilled)

        let square = Rectangle()
        #expect(approx(square.localBounds.size.x, 1))
        #expect(approx(square.localBounds.size.y, 1))

        let triangle = Triangle()
        #expect(approx(triangle.center, .origin, tolerance: 0.2))
    }

    @Test func wallSurfaceCenter() {
        let ceiling = Wall(face: .down)
        // Spec: Wall(face: .down) is the ceiling; its center anchors the pendulum.
        #expect(approx(ceiling.center, Position(0, 2.9, 0)))
        #expect(approx(ceiling.worldBounds.size.x, 4))    // hatches excluded

        let floor = Wall(face: .up)
        #expect(approx(floor.center, Position(0, -2.9, 0)))
    }

    @Test func arrowGeometry() {
        let arrow = Arrow(start: .origin, end: Position(2, 0, 0))
        #expect(arrow.path.contours.count == 2)           // shaft + head
        let bounds = arrow.localBounds
        #expect(approx(bounds.max.x, 2, tolerance: 1e-3))
    }
}
