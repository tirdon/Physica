import Testing
@testable import Physica

@Suite @MainActor struct DragTests {
    private let tolerance: Real = 1e-4

    /// Adds a draggable circle at `position` and flushes the add clip.
    @discardableResult
    private func draggable(
        _ scene: Scene,
        at position: Position,
        payload: DragPayload = .expression(.variable("x")),
        component: DraggableComponent? = nil
    ) -> Circle {
        let dot = Circle(radius: 0.5)
        dot.position = position
        dot.components[DraggableComponent.self] = component ?? DraggableComponent(payload: payload)
        scene.add(dot)
        scene.seek(to: 0)
        return dot
    }

    @Test func topmostPaintedEntityWins() {
        let scene = Scene()
        var tappedFirst = false
        var tappedSecond = false
        let lower = Circle(radius: 0.5)
        let upper = Circle(radius: 0.5)
        lower.components[DraggableComponent.self] = DraggableComponent(
            payload: .tag("a"), onTap: { _ in tappedFirst = true })
        upper.components[DraggableComponent.self] = DraggableComponent(
            payload: .tag("b"), onTap: { _ in tappedSecond = true })
        scene.add(lower, upper) // upper painted last → on top
        scene.seek(to: 0)

        scene.dispatch(.pointerDown(.zero))
        scene.dispatch(.pointerUp(.zero))
        #expect(!tappedFirst)
        #expect(tappedSecond)
    }

    @Test func smallMoveIsTapLargeMoveIsDrag() {
        let scene = Scene()
        var tapped = false
        var dragBegan = false
        draggable(scene, at: .zero, component: DraggableComponent(
            payload: .tag("t"),
            onTap: { _ in tapped = true },
            onDragBegan: { _ in dragBegan = true }))

        // Tap: press and release within the slop.
        scene.dispatch(.pointerDown(.zero))
        scene.dispatch(.pointerMoved(Position(0.05, 0, 0)))
        scene.dispatch(.pointerUp(Position(0.05, 0, 0)))
        #expect(tapped)
        #expect(!dragBegan)
    }

    @Test func pastSlopPromotesToDrag() {
        let scene = Scene()
        var tapped = false
        var dragBegan = false
        draggable(scene, at: .zero, component: DraggableComponent(
            payload: .tag("t"),
            onTap: { _ in tapped = true },
            onDragBegan: { _ in dragBegan = true }))

        scene.dispatch(.pointerDown(.zero))
        scene.dispatch(.pointerMoved(Position(0.3, 0, 0))) // past 0.12 slop
        scene.dispatch(.pointerUp(Position(0.3, 0, 0)))
        #expect(dragBegan)
        #expect(!tapped)
    }

    @Test func tapHandlerReceivesTap() {
        let scene = Scene()
        var tapped = false
        let chip = Circle(radius: 0.5)
        chip.components[TapHandlerComponent.self] = TapHandlerComponent { _ in tapped = true }
        scene.add(chip)
        scene.seek(to: 0)

        scene.dispatch(.pointerDown(.zero))
        scene.dispatch(.pointerUp(.zero))
        #expect(tapped)
    }

    @Test func acceptedDropInvokesOnDropOnce() {
        let scene = Scene()
        draggable(scene, at: Position(-3, 0, 0), payload: .expression(.variable("y")))

        var received: DragPayload?
        let target = Circle(radius: 0.5)
        target.position = Position(3, 0, 0)
        target.components[DropTargetComponent.self] = DropTargetComponent(
            onDrop: { payload, _ in received = payload; return .accepted })
        scene.add(target)
        scene.seek(to: 0)

        scene.dispatch(.pointerDown(Position(-3, 0, 0)))
        scene.dispatch(.pointerMoved(Position(-2.6, 0, 0))) // promote
        scene.dispatch(.pointerMoved(Position(3, 0, 0)))    // over target
        scene.dispatch(.pointerUp(Position(3, 0, 0)))
        #expect(received == .expression(.variable("y")))
    }

    @Test func rejectedDropSnapsDraggedHome() {
        let scene = Scene()
        let dot = draggable(scene, at: Position(-3, 0, 0))

        let target = Circle(radius: 0.5)
        target.position = Position(3, 0, 0)
        target.components[DropTargetComponent.self] = DropTargetComponent(
            onDrop: { _, _ in .rejected })
        scene.add(target)
        scene.seek(to: 0)

        scene.dispatch(.pointerDown(Position(-3, 0, 0)))
        scene.dispatch(.pointerMoved(Position(-2.6, 0, 0)))
        scene.dispatch(.pointerMoved(Position(3, 0, 0)))
        scene.dispatch(.pointerUp(Position(3, 0, 0)))
        // Snap-back rides the interaction runner.
        scene.update(deltaTime: 0.5)
        #expect(abs(dot.position.x - (-3)) < tolerance)
        #expect(scene.interactions.isIdle)
    }

    @Test func offTargetDropSnapsBackViaRunner() {
        let scene = Scene()
        let dot = draggable(scene, at: Position(3, 0, 0))

        scene.dispatch(.pointerDown(Position(3, 0, 0)))
        scene.dispatch(.pointerMoved(Position(3.3, 0, 0))) // promote
        scene.dispatch(.pointerMoved(.zero))               // drag away, no target
        #expect(abs(dot.position.x - 3) > 0.5)             // visibly moved
        scene.dispatch(.pointerUp(.zero))
        scene.update(deltaTime: 0.5)
        #expect(abs(dot.position.x - 3) < tolerance)       // back home
    }

    @Test func hoverEntersAndExits() {
        let scene = Scene()
        draggable(scene, at: Position(-3, 0, 0))

        var hoverStates: [Bool] = []
        let target = Circle(radius: 0.5)
        target.position = Position(3, 0, 0)
        target.components[DropTargetComponent.self] = DropTargetComponent(
            onHoverChanged: { hoverStates.append($0) })
        scene.add(target)
        scene.seek(to: 0)

        scene.dispatch(.pointerDown(Position(-3, 0, 0)))
        scene.dispatch(.pointerMoved(Position(-2.6, 0, 0))) // promote, not over target
        scene.dispatch(.pointerMoved(Position(3, 0, 0)))    // enter
        scene.dispatch(.pointerMoved(.zero))                // exit
        scene.dispatch(.pointerUp(.zero))
        #expect(hoverStates == [true, false])
    }

    @Test func proxyFollowsSourceStaysRemovedAfterReject() {
        let scene = Scene()
        var proxy: Entity?
        let source = draggable(scene, at: Position(3, 0, 0), component: DraggableComponent(
            payload: .tag("t"),
            makeDragProxy: { src in
                let p = Circle(radius: 0.3)
                p.position = src.position
                p.name = "proxy"
                proxy = p
                return p
            }))

        scene.dispatch(.pointerDown(Position(3, 0, 0)))
        scene.dispatch(.pointerMoved(Position(3.3, 0, 0))) // promote — spawns proxy
        scene.dispatch(.pointerMoved(.zero))               // drag proxy away

        #expect(proxy != nil)
        #expect(scene.entities.contains { $0 === proxy })   // proxy is a scene root
        #expect(abs(source.position.x - 3) < tolerance)     // source never moved
        #expect(abs(proxy!.position.x) < 1)                 // proxy followed the pointer

        scene.dispatch(.pointerUp(.zero))                   // off-target → reject
        scene.update(deltaTime: 0.5)                        // snap-back completes
        #expect(!scene.entities.contains { $0 === proxy })  // proxy removed
        #expect(abs(source.position.x - 3) < tolerance)
    }

    @Test func disabledDraggableIsInert() {
        let scene = Scene()
        var dragBegan = false
        draggable(scene, at: .zero, component: DraggableComponent(
            payload: .tag("t"), isEnabled: false, onDragBegan: { _ in dragBegan = true }))

        scene.dispatch(.pointerDown(.zero))
        scene.dispatch(.pointerMoved(Position(0.4, 0, 0)))
        scene.dispatch(.pointerUp(Position(0.4, 0, 0)))
        #expect(!dragBegan)
    }

    @Test func disabledCoordinatorStillTapsChips() {
        let scene = Scene()
        var dragBegan = false
        var chipTapped = false
        draggable(scene, at: Position(-3, 0, 0), component: DraggableComponent(
            payload: .tag("t"), onDragBegan: { _ in dragBegan = true }))
        let chip = Circle(radius: 0.5)
        chip.position = Position(3, 0, 0)
        chip.components[TapHandlerComponent.self] = TapHandlerComponent { _ in chipTapped = true }
        scene.add(chip)
        scene.seek(to: 0)

        scene.drag.isEnabled = false
        // Draggable ignored entirely.
        scene.dispatch(.pointerDown(Position(-3, 0, 0)))
        scene.dispatch(.pointerMoved(Position(-2.5, 0, 0)))
        scene.dispatch(.pointerUp(Position(-2.5, 0, 0)))
        #expect(!dragBegan)
        // Chip tap still lands.
        scene.dispatch(.pointerDown(Position(3, 0, 0)))
        scene.dispatch(.pointerUp(Position(3, 0, 0)))
        #expect(chipTapped)
    }

    @Test func cancelActiveRestoresHomeInstantly() {
        let scene = Scene()
        let dot = draggable(scene, at: Position(2, 1, 0))

        scene.dispatch(.pointerDown(Position(2, 1, 0)))
        scene.dispatch(.pointerMoved(Position(2.4, 1, 0))) // promote
        scene.dispatch(.pointerMoved(.zero))               // drag away
        #expect(abs(dot.position.x - 2) > 0.5)
        scene.drag.cancelActive(in: scene)
        // No tick needed — cancel is instant.
        #expect(abs(dot.position.x - 2) < tolerance)
        #expect(abs(dot.position.y - 1) < tolerance)
    }

    @Test func pointerCancelAbortsDragInstantly() {
        let scene = Scene()
        let dot = draggable(scene, at: Position(2, 1, 0))

        scene.dispatch(.pointerDown(Position(2, 1, 0)))
        scene.dispatch(.pointerMoved(Position(2.4, 1, 0))) // promote
        scene.dispatch(.pointerMoved(.zero))               // drag away
        #expect(abs(dot.position.x - 2) > 0.5)

        scene.dispatch(.pointerCancelled)                  // OS/browser aborts the gesture
        #expect(abs(dot.position.x - 2) < tolerance)       // restored instantly, no tick
        #expect(abs(dot.position.y - 1) < tolerance)
        #expect(!scene.pointer.isDown)
    }

    @Test func pointerCancelRemovesProxy() {
        let scene = Scene()
        var proxy: Entity?
        draggable(scene, at: Position(2, 0, 0), component: DraggableComponent(
            payload: .tag("t"),
            makeDragProxy: { src in
                let p = Circle(radius: 0.3); p.position = src.position; proxy = p; return p
            }))

        scene.dispatch(.pointerDown(Position(2, 0, 0)))
        scene.dispatch(.pointerMoved(Position(2.4, 0, 0)))
        scene.dispatch(.pointerMoved(.zero))
        #expect(scene.entities.contains { $0 === proxy })

        scene.dispatch(.pointerCancelled)
        #expect(!scene.entities.contains { $0 === proxy })
    }

    @Test func cancelActiveRemovesProxy() {
        let scene = Scene()
        var proxy: Entity?
        draggable(scene, at: Position(2, 0, 0), component: DraggableComponent(
            payload: .tag("t"),
            makeDragProxy: { src in
                let p = Circle(radius: 0.3); p.position = src.position; proxy = p; return p
            }))

        scene.dispatch(.pointerDown(Position(2, 0, 0)))
        scene.dispatch(.pointerMoved(Position(2.4, 0, 0)))
        scene.dispatch(.pointerMoved(.zero))
        #expect(scene.entities.contains { $0 === proxy })
        scene.drag.cancelActive(in: scene)
        #expect(!scene.entities.contains { $0 === proxy })
    }

    @Test func dragWorksWhileTimelinePaused() {
        let scene = Scene()
        draggable(scene, at: Position(-3, 0, 0))
        scene.seek(to: 0) // pauses the timeline
        #expect(scene.timeline.isPaused)

        var dropped = false
        let target = Circle(radius: 0.5)
        target.position = Position(3, 0, 0)
        target.components[DropTargetComponent.self] = DropTargetComponent(
            onDrop: { _, _ in dropped = true; return .accepted })
        scene.add(target)
        scene.seek(to: 0)

        scene.dispatch(.pointerDown(Position(-3, 0, 0)))
        scene.dispatch(.pointerMoved(Position(-2.6, 0, 0)))
        scene.dispatch(.pointerMoved(Position(3, 0, 0)))
        scene.dispatch(.pointerUp(Position(3, 0, 0)))
        #expect(dropped) // fired despite the paused timeline
    }

    @Test func hitTestDraggableConsultsEnableState() {
        let scene = Scene()
        draggable(scene, at: .zero)
        #expect(scene.drag.hitTestDraggable(at: .zero, in: scene))
        #expect(!scene.drag.hitTestDraggable(at: Position(5, 5, 0), in: scene))
        scene.drag.isEnabled = false
        #expect(!scene.drag.hitTestDraggable(at: .zero, in: scene))
    }

    @Test func shakeTrackIsScrubSafe() {
        let scene = Scene()
        let dot = Circle(radius: 0.2)
        dot.position = Position(1, 2, 0)
        scene.add(dot)
        scene.seek(to: 0)

        let track = ShakeTrack(
            target: dot, amplitude: 0.2, cycles: 3,
            duration: 0.4, offset: 0, label: "shake")
        track.begin(in: scene)

        track.apply(at: 0, in: scene)
        #expect(abs(dot.position.x - 1) < tolerance) // exact at start

        track.apply(at: 0.05, in: scene)             // mid-wobble
        #expect(abs(dot.position.x - 1) > 0.05)
        #expect(abs(dot.position.y - 2) < tolerance) // y untouched

        track.apply(at: 0.4, in: scene)              // exact at end
        #expect(abs(dot.position.x - 1) < tolerance)

        track.apply(at: 0.05, in: scene)             // perturb again
        #expect(abs(dot.position.x - 1) > 0.05)
        track.rewind(in: scene)
        #expect(abs(dot.position.x - 1) < tolerance) // rewind restores
    }
}
