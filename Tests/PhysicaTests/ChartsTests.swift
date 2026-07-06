// Charts tests — the net-new chart entities: Area/Scatter/Parametric (sampled
// plot variants), BarChart and PieChart (element groups), and their data /
// add / remove animations. Every track is exercised through a scrub round
// trip (seek forward, land exactly, scrub back) per the timeline contract.

import Testing
@testable import PhysicaFoundation
@testable import PhysicaAlgebra
@testable import PhysicaTypesetting
@testable import PhysicaKernel
@testable import PhysicaCharts
@testable import PhysicaPhysics
@testable import PhysicaEquationGame

@Suite @MainActor struct ChartsTests {
    private let tolerance: Real = 1e-3

    // MARK: Sampled plot variants

    @Test func areaClosesEachRunToTheBaseline() {
        let plane = Plane(x: -2...2, y: -1...3)
        let area = plane.area(of: { _ in 2 }, samples: 8)
        #expect(area.lines.count == 1)
        #expect(area.lines[0].count == 8)
        #expect(!area.path.contours.isEmpty)
        let allClosed = area.path.contours.allSatisfy { $0.isClosed }
        #expect(allClosed)
        // The filled contour reaches down to the baseline (y = 0 in data space).
        let baseY = plane.localPoint(0, 0).y
        let minY = area.path.bounds.min.y
        #expect(abs(minY - baseY) < tolerance)
    }

    @Test func areaReplotMorphsSamples() {
        let scene = Scene()
        let plane = Plane(x: -2...2, y: -1...3)
        let area = plane.area(of: { _ in 1 }, samples: 4)
        scene.add(plane)
        scene.add(area)
        scene.play(area.plot { _ in 2 }, for: 1.s)

        scene.seek(to: 0.5)
        let midY = plane.dataY(fromLocalY: area.lines[0][0].y)
        #expect(abs(midY - 1.5) < 0.1)   // eased midpoint stays between
        scene.seek(to: 1)
        #expect(abs(plane.dataY(fromLocalY: area.lines[0][0].y) - 2) < tolerance)
        scene.seek(to: 0)
        #expect(abs(plane.dataY(fromLocalY: area.lines[0][0].y) - 1) < tolerance)
    }

    @Test func scatterStampsOneMarkerPerOnBoardPoint() {
        let plane = Plane(x: -2...2, y: -2...2)
        let scatter = plane.scatter([SIMD2(0, 0), SIMD2(1, 1), SIMD2(5, 5)])   // last off-board
        #expect(scatter.lines[0].count == 3)                  // raw samples all kept
        #expect(scatter.path.contours.count == 2)             // only on-board markers render
    }

    @Test func parametricClipsToBothAxes() {
        let plane = Plane(x: -1...1, y: -1...1)
        // A circle of radius 2 — most of it lies outside the 2×2 board.
        let curve = plane.parametric(t: 0...(2 * Real.pi), samples: 128) { t in
            SIMD2(2 * Real.cos(t), 2 * Real.sin(t))
        }
        #expect(curve.lines[0].count == 128)                  // raw samples intact
        let bounds = curve.path.bounds
        let maxX = plane.localPoint(1, 0).x
        let maxY = plane.localPoint(0, 1).y
        #expect(bounds.max.x <= maxX + tolerance)
        #expect(bounds.max.y <= maxY + tolerance)
    }

    // MARK: Bar chart

    private func barHeight(_ bar: Bar) -> Real {
        bar.path.isEmpty ? 0 : bar.path.bounds.max.y - bar.path.bounds.min.y
    }

    @Test func barChartBuildsBarsAndWhiskers() {
        let chart = BarChart(data: [BarDatum("a", 2, error: 0.5), BarDatum("b", 3)])
        #expect(chart.bars.count == 2)
        #expect(abs(barHeight(chart.bars[0]) - 2) < tolerance)
        #expect(abs(barHeight(chart.bars[1]) - 3) < tolerance)
        #expect(chart.bars[0].errorBar != nil)
        #expect(chart.bars[1].errorBar == nil)
        #expect(abs((chart.bars[0].errorBar?.halfExtent ?? 0) - 0.5) < tolerance)
        #expect(abs(chart.bars[1].position.x - chart.slotStride) < tolerance)
    }

    @Test func barSetMorphsValuesAndScrubsBack() {
        let scene = Scene()
        let chart = BarChart(data: [BarDatum("a", 2), BarDatum("b", 3)])
        scene.add(chart)
        scene.play(chart.set([BarDatum("a", 4), BarDatum("b", 1)]), for: 1.s)

        scene.seek(to: 1)
        #expect(abs(chart.data[0].value - 4) < tolerance)
        #expect(abs(chart.data[1].value - 1) < tolerance)
        scene.seek(to: 0.5)
        #expect(chart.data[0].value > 2 && chart.data[0].value < 4)
        scene.seek(to: 0)
        #expect(abs(chart.data[0].value - 2) < tolerance)
        #expect(abs(chart.data[1].value - 3) < tolerance)
    }

    @Test func barAddGrowsInAndScrubsAway() {
        let scene = Scene()
        let chart = BarChart(data: [BarDatum("a", 2)])
        scene.add(chart)
        scene.play(chart.add(BarDatum("b", 3, error: 0.4)), for: 1.s)

        scene.seek(to: 1)
        #expect(chart.bars.count == 2)
        #expect(abs(chart.data[1].value - 3) < tolerance)
        #expect(abs((chart.bars[1].errorBar?.halfExtent ?? 0) - 0.4) < tolerance)
        #expect(abs(chart.bars[1].position.x - chart.slotStride) < tolerance)

        scene.seek(to: 0.5)
        #expect(chart.bars.count == 2)                 // attached, mid-growth
        #expect(chart.data[1].value > 0 && chart.data[1].value < 3)

        scene.seek(to: 0)                              // clip start: zero-height bar
        #expect(abs(chart.data[1].value) < tolerance)
    }

    @Test func barRemoveShrinksAndClosesTheGap() {
        let scene = Scene()
        let chart = BarChart(data: [BarDatum("a", 2), BarDatum("b", 3), BarDatum("c", 1)])
        scene.add(chart)
        scene.wait(0.5.s)
        scene.play(chart.remove(at: 0), for: 1.s)

        scene.seek(to: 1.5)                            // past the removal
        #expect(chart.bars.count == 2)
        #expect(abs(chart.bars[0].position.x - 0) < tolerance)          // gap closed
        #expect(abs(chart.bars[1].position.x - chart.slotStride) < tolerance)

        scene.seek(to: 0.25)                           // before the removal clip
        #expect(chart.bars.count == 3)
        #expect(abs(chart.data[0].value - 2) < tolerance)
        #expect(abs(chart.bars[1].position.x - chart.slotStride) < tolerance)
    }

    // MARK: Pie chart

    @Test func pieChartLaysOutFractions() {
        let pie = PieChart(slices: [PieSlice("a", 1), PieSlice("b", 1)])
        #expect(pie.wedges.count == 2)
        #expect(abs(pie.wedges[0].sweep + Real.pi) < tolerance)   // clockwise → negative
        #expect(abs(pie.wedges[1].sweep + Real.pi) < tolerance)
        #expect(abs(pie.wedges[0].startAngle - Real.pi / 2) < tolerance)
    }

    @Test func pieSetRenormalizesAndScrubsBack() {
        let scene = Scene()
        let pie = PieChart(slices: [PieSlice("a", 1), PieSlice("b", 1)])
        scene.add(pie)
        scene.play(pie.set([PieSlice("a", 3), PieSlice("b", 1)]), for: 1.s)

        scene.seek(to: 1)
        #expect(abs(pie.wedges[0].sweep + 1.5 * Real.pi) < tolerance)
        #expect(abs(pie.wedges[1].sweep + 0.5 * Real.pi) < tolerance)
        scene.seek(to: 0)
        #expect(abs(pie.wedges[0].sweep + Real.pi) < tolerance)
    }

    @Test func pieAddGrowsWhileOthersMakeRoom() {
        let scene = Scene()
        let pie = PieChart(slices: [PieSlice("a", 1), PieSlice("b", 1)])
        scene.add(pie)
        scene.play(pie.add(PieSlice("c", 1)), for: 1.s)

        scene.seek(to: 1)
        #expect(pie.wedges.count == 3)
        for wedge in pie.wedges {
            #expect(abs(wedge.sweep + 2 * Real.pi / 3) < tolerance)
        }
        scene.seek(to: 0)
        #expect(pie.wedges.count == 3)                 // attached at clip start, zero share
        #expect(abs(pie.wedges[2].sweep) < tolerance)
    }

    @Test func pieRemoveCollapsesAndRestores() {
        let scene = Scene()
        let pie = PieChart(slices: [PieSlice("a", 1), PieSlice("b", 1), PieSlice("c", 2)])
        scene.add(pie)
        scene.wait(0.5.s)
        scene.play(pie.remove(at: 2), for: 1.s)

        scene.seek(to: 1.5)
        #expect(pie.wedges.count == 2)
        #expect(abs(pie.wedges[0].sweep + Real.pi) < tolerance)   // halves again

        scene.seek(to: 0.25)
        #expect(pie.wedges.count == 3)
        #expect(abs(pie.wedges[2].sweep + Real.pi) < tolerance)   // 2 of 4 total
    }

    // MARK: Sector geometry

    @Test func sectorPathClosesThroughTheCenter() {
        let path = Path.sector(center: .zero, radius: 1, startAngle: 0, endAngle: Real.pi / 2)
        #expect(path.contours.count == 1)
        #expect(path.contours[0].isClosed)
        #expect(path.contours[0].start == .zero)
        let zeroSweep = Path.sector(center: .zero, radius: 1, startAngle: 0, endAngle: 0)
        #expect(zeroSweep.isEmpty)
    }
}
