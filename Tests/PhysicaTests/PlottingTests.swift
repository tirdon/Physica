import Foundation
import Testing
@testable import PhysicaMath
@testable import PhysicaAlgebra
@testable import PhysicaGeometry
@testable import PhysicaTypesetting
@testable import PhysicaKernel
@testable import PhysicaPlotting
@testable import PhysicaStory
@testable import PhysicaPhysics
@testable import PhysicaEquationGame

/// Same skip-guard pattern as TTFTests — label tests need a real glyf font.
private func loadLabelFont() -> Font? {
    for path in [
        "/System/Library/Fonts/Supplemental/Arial.ttf",
        "/System/Library/Fonts/Supplemental/Tahoma.ttf",
        "/System/Library/Fonts/Supplemental/Trebuchet MS.ttf",
    ] {
        guard FileManager.default.fileExists(atPath: path),
              let data = FileManager.default.contents(atPath: path) else { continue }
        if let font = try? Font(data: [UInt8](data)) {
            return font
        }
    }
    return nil
}

@Suite @MainActor
struct PlottingTests {
    @Test func planeMapsDataToWorld() {
        // Symmetric ranges, default 1:1 scale → data coords are world coords.
        let plane = Plane(x: -4...4, y: -2...2, gridStep: 1)
        #expect(approx(plane.point(0, 0), Position(0, 0, 0), tolerance: 1e-5))
        #expect(approx(plane.point(4, 2), Position(4, 2, 0), tolerance: 1e-5))

        // Explicit size compresses data units; plane transform shifts results.
        let scaled = Plane(x: 0...10, y: 0...4, gridStep: 1, size: SIMD2(5, 2))
        scaled.position = Position(1, 1, 0)
        #expect(approx(scaled.point(5, 2), Position(1, 1, 0), tolerance: 1e-5))
        #expect(approx(scaled.point(10, 4), Position(3.5, 2, 0), tolerance: 1e-5))
    }

    @Test func planeBuildsGridAndAxes() {
        let plane = Plane(x: -2...2, y: -1...1, gridStep: 1)
        // Grid: 5 vertical + 3 horizontal lattice lines.
        #expect(plane.grid.path.contours.count == 8)
        // Subgrid (2 subdivisions): half-step lines skipping the majors —
        // 4 vertical + 2 horizontal.
        #expect(plane.subgrid.path.contours.count == 6)
        // Each axis is a double-headed Arrow: shaft + a filled tip at each end.
        #expect(plane.xAxis.doubleHeaded)
        #expect(plane.xAxis.path.contours.count == 3)
        #expect(plane.yAxis.path.contours.count == 3)
        // 5 x-ticks + 3 y-ticks.
        #expect(plane.ticks.path.contours.count == 8)
        // subdivisions: 1 → no minor lines.
        let coarse = Plane(x: -2...2, y: -1...1, gridStep: 1, subdivisions: 1)
        #expect(coarse.subgrid.path.isEmpty)

        let scene = Scene()
        scene.add(plane)
        scene.update(deltaTime: 0.016)
        // subgrid + grid + xAxis + yAxis + ticks; labels empty without a font.
        #expect(scene.snapshot().primitives.count == 5)
    }

    @Test func axisArrowsAndOptionsAdjustLive() {
        let plane = Plane(x: -2...2, y: -1...1, gridStep: 1)
        // Arrows span the range plus overhang, tips at both terminals.
        #expect(approx(plane.xAxis.end.x, 2.3, tolerance: 1e-4))
        #expect(approx(plane.yAxis.end.y, 1.3, tolerance: 1e-4))
        #expect(approx(plane.xAxis.headLength, 0.18, tolerance: 1e-4))

        let bare = Plane(
            x: -2...2, y: -1...1, gridStep: 1,
            axis: AxisOptions(tipLength: 0, showTicks: false, showLabels: false)
        )
        #expect(bare.xAxis.path.contours.count == 1)  // shaft only, no head
        #expect(bare.ticks.path.isEmpty)

        // Arrows are real entities — adjust them directly…
        plane.xAxis.headLength = 0.4
        #expect(plane.xAxis.path.contours.count == 3)  // shaft + a head each end
        // …while assigning options re-applies them over direct tweaks.
        var options = plane.axis
        options.overhang = 1
        plane.axis = options
        #expect(approx(plane.xAxis.end.x, 3, tolerance: 1e-4))
        #expect(approx(plane.xAxis.headLength, 0.18, tolerance: 1e-4))
    }

    @Test func tickPointsAndTextLabels() {
        let plane = Plane(x: -2...2, y: -1...1, gridStep: 1)
        plane.position = Position(1, 0, 0)
        // Tick values are the grid multiples; tick points are world positions
        // on the axis lines (annotations hang off these like the labels do).
        #expect(plane.xTickValues == [-2, -1, 0, 1, 2])
        #expect(plane.yTickValues == [-1, 0, 1])
        #expect(approx(plane.tickPoint(x: 1), Position(2, 0, 0), tolerance: 1e-4))
        #expect(approx(plane.tickPoint(y: -1), Position(1, -1, 0), tolerance: 1e-4))
        // No font, no labels (the xLabels/yLabels sub-groups always exist).
        #expect(plane.xLabels.children.isEmpty)
        #expect(plane.yLabels.children.isEmpty)

        guard let font = loadLabelFont() else { return }  // environment-dependent

        // Assigning a font appends one shown TextEntity per tick, zero skipped:
        // x -2,-1,1,2 + y -1,1, reachable through the Group subscript.
        plane.labelFont = font
        #expect(plane.xLabels.children.count == 4)
        #expect(plane.yLabels.children.count == 2)
        let first = plane.xLabels[0] as? TextEntity
        #expect(first?.text == "-2")
        #expect(first?.textComponent.writeProgress == 1)

        // x labels sit below the axis; y labels end left of the y axis.
        if let first {
            #expect(first.position.y < 0)
            #expect(approx(first.position.x, -2, tolerance: 1e-4))
        }
        #expect(plane.yLabels[1].position.x < 0)

        // The origin "0" sits below-left of the axis crossing…
        #expect(plane.originLabel?.text == "0")
        if let origin = plane.originLabel {
            #expect(origin.position.x < 0 && origin.position.y < 0)
        }
        // …but only when the board actually contains the origin.
        let offset = Plane(x: 1...5, y: -1...1, gridStep: 1, font: font)
        #expect(offset.originLabel == nil)

        // Hiding labels rebuilds the groups empty.
        var options = plane.axis
        options.showLabels = false
        plane.axis = options
        #expect(plane.xLabels.children.isEmpty)
        #expect(plane.yLabels.children.isEmpty)
        #expect(plane.originLabel == nil)
    }

    @Test func groupSubscriptReachesChildren() {
        let plane = Plane(x: -2...2, y: -1...1, gridStep: 1)
        // Subscript is plain indexed child access on any Group.
        #expect(plane.axes[0] === plane.xAxis)
        #expect(plane.axes[1] === plane.yAxis)
        #expect(plane.labels[0] === plane.xLabels)

        guard let font = loadLabelFont() else { return }  // environment-dependent
        plane.labelFont = font

        // The example from the API request: color one tick label.
        let scene = Scene()
        scene.add(plane)
        scene.wait(0.5.s)
        scene.play(plane.xLabels[0].color(.red), for: 1.s)
        scene.update(deltaTime: 0.016)

        scene.seek(to: 2.0)
        // FP lerp endpoints aren't bit-exact — compare channels with tolerance.
        let colored = plane.xLabels[0].components[RenderStyleComponent.self]!.color
        #expect(abs(colored.r - Color.red.r) < 1e-3 && abs(colored.g - Color.red.g) < 1e-3)
        // Scrubbing back restores the original label color exactly.
        scene.seek(to: 0.2)
        let restored = plane.xLabels[0].components[RenderStyleComponent.self]?.color
        #expect(restored == Color(hex: 0xDCE6EC))  // default axisColor
    }

    @Test func graphDataAccessTracksLiveValues() {
        let scene = Scene()
        let plane = Plane(x: -2...2, y: -2...2, gridStep: 1)
        let graph = plane.graph(of: { _ in 1 }, samples: 21)
        let dot = Circle(radius: 0.09)
        dot.updater = { $0.position = graph.point(at: 0.5) }
        scene.add(plane, graph, dot)
        scene.wait(0.5.s)
        scene.play(graph.plot { _ in -1 }, for: 1.s, easing: .linear)
        scene.update(deltaTime: 0.016)

        // Midway the live curve sits at y = 0 — value and marker track it
        // (updaters run once after every seek).
        scene.seek(to: 1.0)
        #expect(approx(graph.value(at: 0.5), 0, tolerance: 1e-3))
        #expect(approx(dot.position, Position(0.5, 0, 0), tolerance: 1e-3))

        // End: the new data; an out-of-range x clamps to the curve's end.
        scene.seek(to: 2.0)
        #expect(approx(graph.value(at: 0.5), -1, tolerance: 1e-3))
        #expect(approx(graph.value(at: 99), -1, tolerance: 1e-3))
        #expect(approx(dot.position, Position(0.5, -1, 0), tolerance: 1e-3))
    }

    @Test func sizeModifierAndAspectRescaleTheBoard() {
        let plane = Plane(x: 0...10, y: 0...4, gridStep: 1).size(5, 2)
        #expect(approx(plane.aspectRatio, 2.5, tolerance: 1e-4))
        #expect(approx(plane.point(10, 4), Position(2.5, 1, 0), tolerance: 1e-4))

        let board = Plane(x: -2...2, y: -2...2, gridStep: 1).size(6, aspect: 1.5)
        #expect(approx(board.aspectRatio, 1.5, tolerance: 1e-4))
        #expect(approx(board.point(2, 2), Position(3, 2, 0), tolerance: 1e-4))

        // Graphs sampled after the resize pick up the new scale.
        let graph = board.graph(of: { _ in 2 }, samples: 5)
        #expect(approx(graph.lines[0][0].x, -3, tolerance: 1e-4))
        #expect(approx(graph.lines[0][0].y, 2, tolerance: 1e-4))
    }

    @Test func graphKeepsRawSamplesAndClipsRenderToBoard() {
        let plane = Plane(x: -2...2, y: -1...1, gridStep: 1)
        let graph = plane.graph(of: { $0 * $0 }, samples: 41)

        // Sample data is RAW (unclamped) so re-plots stay topology-stable: the
        // endpoint keeps x² = 4 instead of saturating at the y-range top.
        #expect(graph.lines.count == 1)
        #expect(graph.lines[0].count == 41)
        #expect(approx(graph.lines[0][0].x, -2, tolerance: 1e-4))
        #expect(approx(graph.lines[0][0].y, 4, tolerance: 1e-4))
        #expect(approx(graph.lines[0][20].x, 0, tolerance: 1e-4))
        #expect(approx(graph.lines[0][20].y, 0, tolerance: 1e-4))

        // The RENDERED path is clipped to the board: x² ≤ 1 only for |x| ≤ 1,
        // so the visible curve spans x ∈ [-1, 1] and never leaves the band.
        let bounds = graph.path.bounds
        #expect(approx(bounds.min.x, -1, tolerance: 1e-2))
        #expect(approx(bounds.max.x, 1, tolerance: 1e-2))
        #expect(bounds.max.y <= 1 + 1e-6)
        #expect(bounds.min.y >= -1 - 1e-6)
    }

    // Regression: y = x sampled across x ∈ [-2.2, 2.2] with a tighter y range
    // used to clamp out-of-range samples to ±1.6, drawing flat "shoulders" from
    // the corners out to the x-range edges. The curve must now stop at the board.
    @Test func graphClipsToBoardWithoutShoulders() {
        let plane = Plane(x: -2.2...2.2, y: -1.6...1.6, gridStep: 1)
        let graph = plane.graph(of: { $0 })

        // Raw samples still span the full x range (topology preserved).
        #expect(approx(graph.lines[0].first!.x, -2.2, tolerance: 1e-4))
        #expect(approx(graph.lines[0].last!.x, 2.2, tolerance: 1e-4))

        // One unbroken diagonal, corner to corner — no flat run out to ±2.2.
        #expect(graph.path.contours.count == 1)
        let bounds = graph.path.bounds
        #expect(approx(bounds.min.x, -1.6, tolerance: 2e-2))
        #expect(approx(bounds.max.x, 1.6, tolerance: 2e-2))
        #expect(approx(bounds.min.y, -1.6, tolerance: 2e-2))
        #expect(approx(bounds.max.y, 1.6, tolerance: 2e-2))
    }

    @Test func graphPlotMorphsDataAndScrubsBack() {
        let scene = Scene()
        let plane = Plane(x: -2...2, y: -2...2, gridStep: 1)
        let graph = plane.graph(of: { _ in 1 }, samples: 21)
        scene.add(plane, graph)
        scene.wait(0.5.s)
        scene.play(graph.plot { _ in -1 }, for: 1.s, easing: .linear)
        scene.update(deltaTime: 0.016)

        // Midway: every sample is between the curves.
        scene.seek(to: 1.0)
        #expect(approx(graph.lines[0][10].y, 0, tolerance: 1e-3))
        #expect(graph.lines[0].count == 21)

        // End: exact target data, same topology.
        scene.seek(to: 2.0)
        #expect(approx(graph.lines[0][0].y, -1, tolerance: 1e-4))
        #expect(approx(graph.lines[0][20].y, -1, tolerance: 1e-4))

        // Scrub back before the clip: original data restored exactly.
        scene.seek(to: 0.2)
        #expect(approx(graph.lines[0][10].y, 1, tolerance: 1e-4))
    }

    @Test func plotAcceptsDifferentSampleCounts() {
        let scene = Scene()
        let plane = Plane(x: 0...4, y: 0...4, gridStep: 1)
        let chart = plane.plot([SIMD2(0, 0), SIMD2(2, 2), SIMD2(4, 0)])
        scene.add(plane, chart)
        scene.wait(0.5.s)
        scene.play(chart.plot([SIMD2(0, 1), SIMD2(1, 3), SIMD2(3, 3), SIMD2(4, 1)]), for: 1.s)
        scene.update(deltaTime: 0.016)

        scene.seek(to: 2.0)
        // Lands exactly on the new series (4 points, plane-local coords:
        // data (4,1) → (2,-1), (0,1) → (-2,-1), (3,3) → (1,1)).
        #expect(chart.lines[0].count == 4)
        #expect(approx(chart.lines[0][3].x, 2, tolerance: 1e-4))
        #expect(approx(chart.lines[0][3].y, -1, tolerance: 1e-4))
        #expect(approx(chart.lines[0][0].x, -2, tolerance: 1e-4))
        #expect(approx(chart.lines[0][2].y, 1, tolerance: 1e-4))
    }

    @Test func fieldKeepsTopologyWhileFlowMorphs() {
        let scene = Scene()
        let plane = Plane(x: -2...2, y: -2...2, gridStep: 1)
        // Constant rightward field → every arrow horizontal.
        let field = plane.field { _ in SIMD2(1, 0) }
        let arrowCount = field.samplePoints.count
        #expect(arrowCount == 25)  // 5 × 5 lattice
        #expect(field.path.contours.count == arrowCount * 2)  // shaft + head each

        scene.add(plane, field)
        scene.wait(0.5.s)
        scene.play(field.plot { _ in SIMD2(0, 1) }, for: 1.s, easing: .linear)
        scene.update(deltaTime: 0.016)

        // Midway the vectors lerp (45° here); topology unchanged.
        scene.seek(to: 1.0)
        #expect(approx(field.vectors[0].x, 0.5, tolerance: 1e-3))
        #expect(approx(field.vectors[0].y, 0.5, tolerance: 1e-3))
        #expect(field.path.contours.count == arrowCount * 2)

        // End: exact target field; scrub back restores the original exactly.
        scene.seek(to: 2.0)
        #expect(approx(field.vectors[12].x, 0, tolerance: 1e-4))
        #expect(approx(field.vectors[12].y, 1, tolerance: 1e-4))
        scene.seek(to: 0.2)
        #expect(approx(field.vectors[12].x, 1, tolerance: 1e-4))
        #expect(approx(field.vectors[12].y, 0, tolerance: 1e-4))
    }

    @Test func streamlinesStayOnBoardWithConstantTopology() {
        let plane = Plane(x: -2...2, y: -2...2, gridStep: 1)
        // Rotation field: closed orbits around the origin.
        let lines = plane.streamlines(steps: 40, dt: 0.05) { p in SIMD2(-p.y, p.x) }

        #expect(lines.lines.count == 16)  // 4 × 4 cell-center seeds
        for line in lines.lines {
            #expect(line.count == 41)  // steps + 1, frozen at exits
            for point in line {
                #expect(point.x >= -2.001 && point.x <= 2.001)
                #expect(point.y >= -2.001 && point.y <= 2.001)
            }
        }

        // Re-plot keeps seeds/steps → identical topology after the morph.
        let scene = Scene()
        scene.add(plane, lines)
        scene.wait(0.5.s)
        scene.play(lines.plot { p in SIMD2(p.y, -p.x) }, for: 1.s)
        scene.update(deltaTime: 0.016)
        scene.seek(to: 2.0)
        #expect(lines.lines.count == 16)
        #expect(lines.lines[0].count == 41)
    }

    @Test func drawRevealsAGraphWithoutExplicitAdd() {
        let scene = Scene()
        let plane = Plane(x: -2...2, y: -1...1, gridStep: 1)
        let graph = plane.graph(of: { x in Real.sin(x) })
        scene.add(plane)
        scene.wait(0.5.s)
        scene.play(.draw(graph), for: 1.s)
        scene.update(deltaTime: 0.016)

        scene.seek(to: 2.0)
        #expect(graph.scene === scene)
        #expect(approx(graph.components[PathComponent.self]!.strokeProgress, 1))

        // Scrubbing before the draw removes it again.
        scene.seek(to: 0.2)
        #expect(graph.scene == nil)
    }
}
