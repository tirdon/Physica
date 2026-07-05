import Testing
@testable import PhysicaFoundation
@testable import PhysicaAlgebra
@testable import PhysicaTypesetting
@testable import PhysicaKernel
@testable import PhysicaCharts
@testable import PhysicaPhysics
@testable import PhysicaEquationGame

// Scene membership has ONE truth: graph reachability (`Scene.contains` — the
// entity is a root, or some ancestor is). These pin the Phase-4a redesign:
// child-first adds never double-root, add/draw order is irrelevant, detach
// clears the whole subtree's cached pointers, and transient animation bags
// never confuse membership.

@Suite @MainActor
struct SceneMembershipTests {
    @Test func childFirstAddAdoptsRootIntoParent() {
        let scene = Scene()
        let plane = Plane(x: -2...2, y: -1...1, gridStep: 1)
        scene.add(plane.grid)     // child first — a root for now
        scene.add(plane)          // parent arrives and adopts it
        scene.update(deltaTime: 0.001)

        #expect(scene.entities.count == 1)
        #expect(scene.entities[0] === plane)
        #expect(scene.contains(plane.grid))
    }

    @Test func addThenDrawChildDoesNotDoubleRoot() {
        let scene = Scene()
        let plane = Plane(x: -2...2, y: -1...1, gridStep: 1)
        scene.add(plane)
        scene.play(.draw(plane.grid), for: 0.5.s)
        scene.update(deltaTime: 1)

        #expect(scene.entities.count == 1)
        #expect(scene.entities[0] === plane)
        #expect(scene.contains(plane.grid))
    }

    @Test func detachClearsSubtreePointersAndReaddWorks() {
        let scene = Scene()
        let group = Group(Circle(), Circle())
        scene.add(group)
        scene.update(deltaTime: 0.001)
        let child = group.children[0]
        #expect(child.scene === scene)

        scene.remove(group)
        #expect(child.scene == nil)
        #expect(!scene.contains(child))

        scene.add(group)
        scene.update(deltaTime: 0.001)
        #expect(child.scene === scene)
        #expect(scene.contains(child))
    }

    @Test func transientBagDoesNotStealMembership() {
        let scene = Scene()
        let a = Circle()
        scene.add(a)
        scene.update(deltaTime: 0.001)

        let bag = Group(a)        // never joins the scene
        #expect(scene.contains(a))
        #expect(!scene.contains(bag))
        #expect(scene.entities.count == 1)
    }

    @Test func scrubAcrossChildFirstAddStaysConsistent() {
        let scene = Scene()
        let plane = Plane(x: -2...2, y: -1...1, gridStep: 1)
        scene.add(plane.grid)
        scene.wait(0.5.s)
        scene.add(plane)
        scene.update(deltaTime: 1)
        #expect(scene.entities.count == 1)
        #expect(scene.entities[0] === plane)

        // Between the adds: the grid alone, as its own root.
        scene.seek(to: 0.25)
        #expect(scene.entities.count == 1)
        #expect(scene.entities.first === plane.grid)

        // Forward again: the plane adopts the grid root, no duplicate.
        scene.seek(to: 1)
        #expect(scene.entities.count == 1)
        #expect(scene.entities.first === plane)
        #expect(scene.contains(plane.grid))
    }
}
