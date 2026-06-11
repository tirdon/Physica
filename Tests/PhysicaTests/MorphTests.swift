import Testing
@testable import Physica

@Suite @MainActor
struct MorphTests {
    @Test func matchedTopologyHasEqualCounts() {
        let matched = PathMorph.matched(.circle(radius: 1), .rect(width: 2, height: 1))
        #expect(matched.from.count == matched.to.count)
        for (from, to) in zip(matched.from, matched.to) {
            #expect(from.points.count == to.points.count)
            #expect(from.points.count >= 32)
        }
    }

    @Test func endpointsMatchSourceAndTarget() {
        let circle = Path.circle(radius: 1)
        let rect = Path.rect(width: 2, height: 2)
        let matched = PathMorph.matched(circle, rect)

        // t=0 stays on the circle, t=1 lands on the rect outline.
        for point in PathMorph.interpolate(matched, t: 0)[0].points {
            #expect(approx(point.distance(), 1, tolerance: 1e-2))
        }
        for point in PathMorph.interpolate(matched, t: 1)[0].points {
            let onEdge = approx(Swift.abs(point.x), 1, tolerance: 1e-2)
                || approx(Swift.abs(point.y), 1, tolerance: 1e-2)
            #expect(onEdge)
            #expect(Swift.abs(point.x) <= 1.01 && Swift.abs(point.y) <= 1.01)
        }
    }

    @Test func contourCountBalancing() {
        // Ring (2 contours) → circle (1): the extra contour collapses to a point.
        let ring = Path.circle(radius: 1).appending(
            Path.circle(radius: 0.5).transformedPoints { SIMD2($0.x, -$0.y) }  // reversed winding hole
        )
        let circle = Path.circle(radius: 0.8)
        let matched = PathMorph.matched(ring, circle)
        #expect(matched.from.count == 2)
        #expect(matched.to.count == 2)

        let final = PathMorph.interpolate(matched, t: 1)
        let collapsed = final[1]
        let spread = collapsed.points.map { ($0 - collapsed.points[0]).distance() }.max() ?? 0
        #expect(spread < 1e-3)  // degenerate point contour
    }

    @Test func windingsAreAligned() {
        let matched = PathMorph.matched(.circle(radius: 1), .circle(radius: 2))
        let areaFrom = PathMorph.signedArea(matched.from[0])
        let areaTo = PathMorph.signedArea(matched.to[0])
        #expect(areaFrom * areaTo > 0)
    }

    @Test func morphAnimationThroughTimeline() {
        let scene = Scene()
        let circle = Circle(radius: 1)
        let square = Rectangle(width: 2, height: 2)
        scene.add(circle)
        scene.play(circle.morph(to: square), for: 1.s, easing: .linear)

        scene.update(deltaTime: 0.5)
        // Area grows from π (circle) toward 4 (square) — mid lies strictly between.
        let midArea = Swift.abs(PathMorph.signedArea(circle.path.flattened()[0]))
        #expect(midArea > 3.2 && midArea < 3.95)

        scene.update(deltaTime: 0.6)
        #expect(circle.path == Path.rect(width: 2, height: 2))  // snapped to true target

        scene.seek(to: 0)
        #expect(circle.path == Path.circle(radius: 1))  // rewound to original
    }

    @Test func drawRevealsStrokeThenFill() {
        let scene = Scene()
        let triangle = Triangle()
        scene.play(.draw(triangle), for: 1.s, easing: .linear)  // auto-added by the play clip

        scene.update(deltaTime: 0.4)
        var component = triangle.components[PathComponent.self]!
        #expect(approx(component.strokeProgress, 0.4 / 0.85, tolerance: 1e-2))
        #expect(component.fillOpacityFactor == 0)

        scene.update(deltaTime: 0.7)
        component = triangle.components[PathComponent.self]!
        #expect(approx(component.strokeProgress, 1))
        #expect(approx(component.fillOpacityFactor, 1))
    }
}

@Suite @MainActor
struct MeshTests {
    @Test func primitiveTopology() {
        let sphere = Mesh.sphere(radius: 1, segments: 24, rings: 16)
        #expect(sphere.positions.count == 25 * 17)
        #expect(sphere.indices.count == 24 * 16 * 6)
        #expect(sphere.normals.count == sphere.positions.count)

        let box = Mesh.box(size: SIMD3(1, 2, 3))
        #expect(box.positions.count == 24)
        #expect(box.indices.count == 36)

        let torus = Mesh.torus(majorRadius: 1, minorRadius: 0.3, majorSegments: 32, minorSegments: 16)
        #expect(torus.positions.count == 33 * 17)
        #expect(approx(torus.bounds.max.x, 1.3, tolerance: 1e-3))
    }

    @Test func sphereGeometryIsOnSurface() {
        let sphere = Mesh.sphere(radius: 2)
        for position in sphere.positions {
            #expect(approx(position.length, 2, tolerance: 1e-3))
        }
        for (position, normal) in zip(sphere.positions, sphere.normals) {
            #expect(approx(normal.length, 1, tolerance: 1e-3))
            #expect(normal.dot(position) > 0)  // outward
        }
    }

    @Test func ellipsoidNormals() {
        let ellipsoid = Mesh.ellipsoid(radii: SIMD3(2, 1, 1))
        for normal in ellipsoid.normals {
            #expect(approx(normal.length, 1, tolerance: 1e-3))
        }
    }

    @Test func sameTopologyMorphLerpsDirectly() {
        let sphere = Mesh.sphere(radius: 1)
        let ellipsoid = Mesh.ellipsoid(radii: SIMD3(2, 1, 1))
        let matched = MeshMorph.matched(sphere, ellipsoid)
        #expect(matched.from.indices == sphere.indices)  // no resample needed

        let mid = MeshMorph.interpolate(matched, t: 0.5)
        #expect(approx(mid.bounds.max.x, 1.5, tolerance: 1e-2))
        #expect(approx(mid.bounds.max.y, 1, tolerance: 1e-2))
    }

    @Test func differentTopologyResamples() {
        let box = Mesh.box(size: SIMD3(2, 2, 2))
        let sphere = Mesh.sphere(radius: 1)
        let matched = MeshMorph.matched(box, sphere)
        #expect(matched.from.positions.count == matched.to.positions.count)
        #expect(matched.from.indices == matched.to.indices)

        // The box resample preserves its extents along the axes.
        #expect(approx(matched.from.bounds.max.y, 1, tolerance: 0.05))
        let final = MeshMorph.interpolate(matched, t: 1)
        for position in final.positions {
            #expect(position.length < 1.05)
        }
    }

    @Test func meshEntityInSnapshot() {
        let scene = Scene()
        let ball = MeshEntity(mesh: .sphere(radius: 0.5), color: .red)
        scene.add(ball.move(to: Position(0, 2, 0)))
        scene.update(deltaTime: 0.016)

        let primitives = scene.snapshot().primitives
        #expect(primitives.count == 1)
        guard case .mesh(let draw) = primitives[0] else {
            Issue.record("expected mesh primitive")
            return
        }
        #expect(draw.positions.count == 25 * 17)
        #expect(approx(draw.model.transformPoint(.origin), Position(0, 2, 0)))
    }
}
