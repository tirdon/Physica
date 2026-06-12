import Testing
@testable import Physica

/// Captures snapshots instead of drawing them.
@MainActor
final class MockRenderBackend: RenderBackend {
    var aspectRatio: Real { 1.6 }
    var rendered: [SceneSnapshot] = []

    func render(_ snapshot: SceneSnapshot) {
        rendered.append(snapshot)
    }
}

@Suite @MainActor
struct SnapshotTests {
    @Test func pathPrimitiveCarriesWorldSpacePoints() {
        let scene = Scene()
        let circle = Circle(radius: 1)
        scene.add(circle.move(to: Position(2, 1, 0)))
        scene.update(deltaTime: 0.016)

        let snapshot = scene.snapshot()
        #expect(snapshot.primitives.count == 1)
        guard case .path(let primitive) = snapshot.primitives[0] else {
            Issue.record("expected a path primitive")
            return
        }
        #expect(primitive.style.fill != nil)
        #expect(primitive.style.stroke == nil)

        // All points lie on a unit circle centered at (2, 1).
        for point in primitive.contours[0].points {
            let r = (point - Position(2, 1, 0)).length
            #expect(approx(r, 1, tolerance: 5e-3))
        }
    }

    @Test func shadingFlowsToMeshDraw() {
        let scene = Scene()
        let ball = MeshEntity(mesh: .sphere(radius: 0.5), color: .red).shaded(.toon)
        let plain = MeshEntity(mesh: .sphere(radius: 0.5), color: .blue)
        scene.add(ball, plain)
        scene.update(deltaTime: 0.016)

        let primitives = scene.snapshot().primitives
        guard case .mesh(let toonDraw) = primitives[0], case .mesh(let plainDraw) = primitives[1]
        else {
            Issue.record("expected mesh primitives")
            return
        }
        #expect(toonDraw.shading == .toon)
        #expect(toonDraw.shading == .toon(bands: 3, outline: 0.035))
        #expect(plainDraw.shading == .lambert)
    }

    @Test func textureFlowsToPathAndTextStyles() {
        let scene = Scene()
        let shape = Circle(radius: 1).textured(.chalk)
        shape.position = Position(2, -1, 0)
        let text = TextEntity(glyphs: [
            TextComponent.PositionedGlyph(path: .rect(width: 0.5, height: 0.7), offset: .zero)
        ]).shown().textured(.pencil)
        scene.add(shape, text)
        scene.update(deltaTime: 0.016)

        let primitives = scene.snapshot().primitives
        guard case .path(let shapeStyle) = primitives[0], case .path(let glyph) = primitives[1]
        else {
            Issue.record("expected path primitives")
            return
        }
        #expect(shapeStyle.style.texture == .chalk)
        #expect(glyph.style.texture == .pencil)
        // The entity position seeds the grain so it travels with the entity.
        #expect(approx(shapeStyle.style.textureSeed.x, 2))
        #expect(approx(shapeStyle.style.textureSeed.y, -1))
        #expect(approx(glyph.style.textureSeed.x, 0))
    }

    @Test func painterOrderFollowsSceneOrder() {
        let scene = Scene()
        let a = Circle()
        a.name = "a"
        let b = Rectangle()
        b.name = "b"
        scene.add(a, b)
        scene.update(deltaTime: 0.016)

        let snapshot = scene.snapshot()
        #expect(snapshot.primitives.count == 2)
        #expect(snapshot.debugString.contains("primitives(2)"))
    }

    @Test func opacityMultipliesIntoColors() {
        let scene = Scene()
        let circle = Circle()
        scene.add(circle)
        scene.play(circle.fade(to: 0.5), for: 1.s, easing: .linear)
        scene.update(deltaTime: 1.0)

        guard case .path(let primitive) = scene.snapshot().primitives[0] else {
            Issue.record("expected a path primitive")
            return
        }
        #expect(approx(Real(primitive.style.fill!.a), 0.5, tolerance: 1e-3))
    }

    @Test func debugLabelsOnlyWhenRequested() {
        let scene = Scene()
        let group = Group(Circle(), Rectangle())
        scene.add(group)
        scene.update(deltaTime: 0.016)

        #expect(scene.snapshot().debugLabels.isEmpty)

        let labels = scene.snapshot(includeDebugLabels: true).debugLabels
        #expect(labels.map(\.text) == ["0", "0.0", "0.1"])
    }

    @Test func debugLabelsSkipInvisibleEntities() {
        let scene = Scene()
        let visible = Circle()
        let faded = Circle()
        let rect = Rectangle()
        let tri = Triangle()
        let group = Group(rect, tri)
        scene.add(visible, faded, group)
        scene.update(deltaTime: 0.016)
        scene.play(faded.fade(to: 0), rect.fade(to: 0), tri.fade(to: 0), for: 0.5.s)
        scene.update(deltaTime: 1.0)

        // faded ("1") gone; group ("2") hides because nothing under it is visible.
        let labels = scene.collectDebugLabels()
        #expect(labels.map(\.text) == ["0"])
    }

    @Test func groupTransformAppliesToChildPrimitives() {
        let scene = Scene()
        let circle = Circle(radius: 0.5)
        let group = Group(circle)
        scene.add(group)
        scene.update(deltaTime: 0.016)
        scene.play(group.shift(3.i), for: 1.s)
        scene.update(deltaTime: 1.0)

        guard case .path(let primitive) = scene.snapshot().primitives[0] else {
            Issue.record("expected a path primitive")
            return
        }
        let centroid = primitive.contours[0].points.reduce(Position.zero, +)
            / Real(primitive.contours[0].points.count)
        #expect(approx(centroid, Position(3, 0, 0), tolerance: 1e-2))
    }

    @Test func engineTicksOnlyVisibleScenes() {
        let engine = Engine()
        let backend = MockRenderBackend()
        let scene = engine.makeScene(name: "demo") { scene in
            scene.add(Circle())
        }
        engine.bind(backend, to: scene)

        engine.tick(deltaTime: 0.016)
        #expect(backend.rendered.count == 1)

        engine.setVisibility(false, forSceneID: scene.id)
        engine.tick(deltaTime: 0.016)
        #expect(backend.rendered.count == 1)  // skipped while off-screen

        engine.setVisibility(true, forSceneID: scene.id)
        engine.tick(deltaTime: 0.016)
        #expect(backend.rendered.count == 2)
        #expect(approx(scene.viewportAspect, 1.6))
    }

    @Test func unitMoveUsesCameraFrame() {
        let scene = Scene()  // fit extent 10, aspect 1.6 → frame 10 × 6.25
        let circle = Circle(radius: 0.5)
        scene.add(circle)
        scene.play(circle.move(to: .bottom), for: 1.s)
        scene.update(deltaTime: 2.0)

        // bottom edge −3.125, padding 0.5, half-extent 0.5 → y = −2.125
        #expect(approx(circle.position.y, -2.125))
        #expect(approx(circle.position.x, 0))
    }

    @Test func fitFrameFollowsAspect() {
        let camera = Camera()  // default fit extent 10
        let landscape = camera.visibleRect(aspect: 1.6)
        #expect(approx(landscape.size.x, 10))
        #expect(approx(landscape.size.y, 6.25))

        let portrait = camera.visibleRect(aspect: 0.5)
        #expect(approx(portrait.size.x, 5))
        #expect(approx(portrait.size.y, 10))

        let square = camera.visibleRect(aspect: 1)
        #expect(approx(square.size.x, 10))
        #expect(approx(square.size.y, 10))
    }

    @Test func backgroundFlowsToSnapshot() {
        let scene = Scene()
        #expect(scene.snapshot().background == .color(.background))

        scene.background = .blackboard
        let snapshot = scene.snapshot()
        #expect(snapshot.background == .blackboard(tint: Color(hex: 0x1C2A24)))
        #expect(snapshot.background.baseColor == Color(hex: 0x1C2A24))
        // The frame rides along so the renderer can size the backdrop quad.
        #expect(approx(snapshot.frame.size.x, scene.frameBounds.size.x))
    }

    @Test func strokeTrimAndNeonFlowToPathPrimitive() {
        let scene = Scene()
        let shape = Circle(radius: 1).stroke(.teal, width: 0.05, cap: .round)
        var style = shape.style
        style.neon = true
        shape.style = style
        var component = shape.components[PathComponent.self]!
        component.strokeProgress = 0.8
        component.strokeStart = 0.3
        shape.components[PathComponent.self] = component
        scene.add(shape)
        scene.update(deltaTime: 0.016)

        guard case .path(let primitive) = scene.snapshot().primitives[0] else {
            Issue.record("expected a path primitive")
            return
        }
        #expect(primitive.style.neon)
        #expect(primitive.style.cap == .round)
        #expect(approx(primitive.strokeProgress, 0.8))
        #expect(approx(primitive.strokeStart, 0.3))
    }
}
