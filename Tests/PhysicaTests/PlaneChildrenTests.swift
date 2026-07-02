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

// Phase-4b redesign pins: plots are plane children. Revealing one attaches it
// lazily to its plane (nothing shows before its reveal clip), the board's
// transform carries every plot, and `plane.size(...)` re-derives plots from
// their data-space sample mirror — before OR after sampling.

@Suite @MainActor
struct PlaneChildrenTests {
    @Test func revealAttachesGraphAsPlaneChild() {
        let scene = Scene()
        let plane = Plane(x: -2...2, y: -1...1, gridStep: 1)
        let graph = plane.graph(of: { x in Real.sin(x) })
        scene.add(plane)
        scene.wait(0.5.s)
        scene.play(.draw(graph), for: 1.s)
        scene.update(deltaTime: 0.016)

        // Before the draw clip: on no board (factories don't attach).
        #expect(graph.parent == nil)

        scene.seek(to: 2.0)
        #expect(graph.parent === plane)
        #expect(scene.entities.count == 1)
        #expect(scene.contains(graph))

        // Scrubbing before the draw takes it back off the plane.
        scene.seek(to: 0.2)
        #expect(graph.parent == nil)
        #expect(graph.scene == nil)

        // Forward again: attached again, still exactly one root.
        scene.seek(to: 2.0)
        #expect(graph.parent === plane)
        #expect(scene.entities.count == 1)
    }

    @Test func planeMoveCarriesAttachedPlots() {
        let scene = Scene()
        let plane = Plane(x: -2...2, y: -2...2, gridStep: 1)
        let graph = plane.graph(of: { _ in 1 })
        scene.add(plane, graph)
        scene.wait(0.5.s)
        scene.play(plane.shift(Position(3, 0, 0)), for: 1.s)
        scene.update(deltaTime: 0.016)

        scene.seek(to: 2.0)
        // The curve's world point rides the plane — no explicit Group needed.
        #expect(approx(graph.point(at: 0), Position(3, 1, 0), tolerance: 1e-3))
    }

    @Test func resizeAfterSamplingRederivesPlots() {
        let plane = Plane(x: -2...2, y: -2...2, gridStep: 1)
        let graph = plane.graph(of: { _ in 2 }, samples: 5)
        // Sampled at 1:1: local x spans [-2, 2].
        #expect(approx(graph.lines[0][0].x, -2, tolerance: 1e-4))
        #expect(approx(graph.lines[0][0].y, 2, tolerance: 1e-4))

        // Resize AFTER sampling — the graph re-derives to the new scale,
        // matching what sampling after the resize would have produced.
        plane.size(6, aspect: 1.5)
        #expect(approx(graph.lines[0][0].x, -3, tolerance: 1e-4))
        #expect(approx(graph.lines[0][0].y, 2, tolerance: 1e-4))
        // Annotation access agrees with the board mapping.
        #expect(approx(graph.point(at: 2), plane.point(2, 2), tolerance: 1e-4))
    }

    @Test func resizeRemapsStreamlinesAndFields() {
        let plane = Plane(x: -2...2, y: -2...2, gridStep: 1)
        let flow = plane.streamlines(steps: 10, dt: 0.05) { p in SIMD2(-p.y, p.x) }
        let field = plane.field { _ in SIMD2(1, 0) }
        let flowXBefore = flow.lines[0][0].x
        let arrowCount = field.path.contours.count

        plane.size(8, 8)  // 2× scale on both axes
        #expect(approx(flow.lines[0][0].x, flowXBefore * 2, tolerance: 1e-3))
        // Same topology, arrows rebuilt to the new cell size.
        #expect(field.path.contours.count == arrowCount)
        #expect(flow.lines[0].count == 11)
    }

    @Test func eraseRemovesAndRestoresChildPlot() {
        let scene = Scene()
        let plane = Plane(x: -2...2, y: -1...1, gridStep: 1)
        let graph = plane.graph(of: { x in x })
        scene.add(plane, graph)
        scene.wait(0.5.s)
        scene.play(.erase(graph), for: 1.s)
        scene.update(deltaTime: 0.016)

        scene.seek(to: 2.0)
        #expect(graph.parent == nil)          // erased off the plane
        #expect(!scene.contains(graph))

        scene.seek(to: 0.2)                    // before the erase
        #expect(graph.parent === plane)        // restored at its child slot
        #expect(scene.contains(graph))
    }
}
