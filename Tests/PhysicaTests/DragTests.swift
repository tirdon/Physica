import Testing
@testable import PhysicaFoundation
@testable import PhysicaAlgebra
@testable import PhysicaTypesetting
@testable import PhysicaKernel
@testable import PhysicaCharts
@testable import PhysicaPhysics
@testable import PhysicaEquationGame

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

    @Test func tapHandlerReceivesSceneAndEntity() {
        let scene = Scene()
        var gotScene: Scene?
        var gotEntity: Entity?
        let dot = Circle(radius: 0.5)
        dot.components[TapComponent.self] = TapComponent { s, e in gotScene = s; gotEntity = e }
        scene.add(dot)
        scene.seek(to: 0)
        scene.dispatch(.pointerDown(.zero))
        scene.dispatch(.pointerUp(.zero))
        #expect(gotScene === scene)
        #expect(gotEntity === dot)
    }

    @Test func doubleTapHandlerReceivesSceneAndEntity() {
        let scene = Scene()
        var gotScene: Scene?
        var gotEntity: Entity?
        let dot = Circle(radius: 0.5)
        dot.components[DoubleTapComponent.self] = DoubleTapComponent { s, e in gotScene = s; gotEntity = e }
        scene.add(dot)
        scene.seek(to: 0)
        scene.dispatch(.doubleClick(.zero))
        #expect(gotScene === scene)
        #expect(gotEntity === dot)
    }

    @Test func legacyOneArgTapStillFires() {
        let scene = Scene()
        var tappedEntity: Entity?
        let dot = Circle(radius: 0.5)
        dot.components[TapComponent.self] = TapComponent { e in tappedEntity = e }
        scene.add(dot)
        scene.seek(to: 0)
        scene.dispatch(.pointerDown(.zero))
        scene.dispatch(.pointerUp(.zero))
        #expect(tappedEntity === dot)
    }

    @Test func handlerOwnerIsImplicitInsideTapAndDoubleTap() {
        let scene = Scene()
        let owner = Circle(radius: 0.5)
        let cx = Circle(radius: 0.2)
        // Neither handler passes an explicit owner — the coordinator supplies the
        // tapped entity, so the reveal is owned by `owner` and the double-tap clears it.
        owner.components[TapComponent.self] = TapComponent { current, _ in
            current.interact(.draw(cx), for: 0.6.s)
        }
        owner.components[DoubleTapComponent.self] = DoubleTapComponent { current, _ in
            current.interrupt()
        }
        scene.add(owner)
        scene.seek(to: 0)

        scene.dispatch(.pointerDown(.zero))
        scene.dispatch(.pointerUp(.zero))
        #expect(scene.entities.contains(where: { $0 === cx }))
        #expect(scene.hasInteraction(ownedBy: owner))

        scene.dispatch(.doubleClick(.zero))
        #expect(!scene.entities.contains(where: { $0 === cx }))
        #expect(!scene.hasInteraction(ownedBy: owner))
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

    @Test func grabOffsetAnchorsToPressNotPostSlop() {
        // A fast first move (flick) jumps far past the slop in one event. The
        // grab must stay anchored to the press point, so the spot the finger
        // touched keeps sitting under the pointer — the flick distance must not
        // leak into the offset and push the payload away.
        let scene = Scene()
        let dot = draggable(scene, at: .zero) // radius 0.5, center at origin
        scene.dispatch(.pointerDown(Position(0.3, 0, 0)))  // off-center grab, within slop
        scene.dispatch(.pointerMoved(Position(2, 0, 0)))   // big first move past 0.12 slop
        // center should trail the pointer by the press offset (0.3), so the
        // grabbed point lands under the pointer: 2 - 0.3 = 1.7.
        #expect(abs(dot.position.x - 1.7) < tolerance)
    }

    @Test func tapHandlerReceivesTap() {
        let scene = Scene()
        var tapped = false
        let chip = Circle(radius: 0.5)
        chip.components[TapComponent.self] = TapComponent { _ in tapped = true }
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

    // MARK: HoverComponent (bare-pointer hover, no button held)

    @Test func hoverComponentTracksBarePointer() {
        let scene = Scene()
        var states: [Bool] = []
        let box = Circle(radius: 0.5)
        box.position = Position(3, 0, 0)
        box.components[HoverComponent.self] = HoverComponent { _, over in states.append(over) }
        scene.add(box)
        scene.seek(to: 0) // pauses — hover is pause-independent, like drag

        scene.dispatch(.pointerMoved(Position(3, 0, 0))) // bare move onto the box → enter
        scene.dispatch(.pointerMoved(Position(3.1, 0, 0))) // still over it → no re-fire
        scene.dispatch(.pointerMoved(.zero))               // off the box → leave
        #expect(states == [true, false])
        #expect(!scene.pointer.isDown) // never pressed
    }

    @Test func clearHoverFiresLeave() {
        let scene = Scene()
        var states: [Bool] = []
        let box = Circle(radius: 0.5)
        box.components[HoverComponent.self] = HoverComponent { _, over in states.append(over) }
        scene.add(box)
        scene.seek(to: 0)

        scene.dispatch(.pointerMoved(.zero)) // enter
        scene.drag.clearHover()              // cursor left the canvas
        #expect(states == [true, false])
    }

    @Test func hoverTopmostPaintedWins() {
        let scene = Scene()
        var lowerEntered = false
        var upperEntered = false
        let lower = Circle(radius: 0.5)
        let upper = Circle(radius: 0.5)
        lower.components[HoverComponent.self] = HoverComponent { _, over in if over { lowerEntered = true } }
        upper.components[HoverComponent.self] = HoverComponent { _, over in if over { upperEntered = true } }
        scene.add(lower, upper) // upper painted last → on top
        scene.seek(to: 0)

        scene.dispatch(.pointerMoved(.zero))
        #expect(!lowerEntered)
        #expect(upperEntered)
    }

    // MARK: Double-click

    @Test func doubleClickFiresOnTopmost() {
        let scene = Scene()
        var clicked: Entity?
        let lower = Circle(radius: 0.5)
        let upper = Circle(radius: 0.5)
        lower.components[DoubleTapComponent.self] = DoubleTapComponent { _ in clicked = lower }
        upper.components[DoubleTapComponent.self] = DoubleTapComponent { e in clicked = e }
        scene.add(lower, upper) // upper on top
        scene.seek(to: 0)

        scene.dispatch(.doubleClick(.zero))
        #expect(clicked === upper) // topmost, and the handler got its own entity
    }

    @Test func doubleClickMissesEmptySpace() {
        let scene = Scene()
        var fired = false
        let box = Circle(radius: 0.5)
        box.components[DoubleTapComponent.self] = DoubleTapComponent { _ in fired = true }
        scene.add(box)
        scene.seek(to: 0)

        scene.dispatch(.doubleClick(Position(5, 5, 0))) // nowhere near the box
        #expect(!fired)
    }

    @Test func doubleClickStaysLiveWhileDragDisabled() {
        let scene = Scene()
        var fired = false
        let box = Circle(radius: 0.5)
        box.components[DoubleTapComponent.self] = DoubleTapComponent { _ in fired = true }
        scene.add(box)
        scene.seek(to: 0)

        scene.drag.isEnabled = false // chips up — a discrete click is not a drag grab
        scene.dispatch(.doubleClick(.zero))
        #expect(fired)
    }

    @Test func doubleClickHighlightsItself() {
        let scene = Scene()
        let star = Circle(radius: 0.5)
        star.position = Position(1, 0, 0)
        star.components[DoubleTapComponent.self] = .highlightSelf()
        scene.add(star)
        scene.seek(to: 0)

        scene.dispatch(.doubleClick(Position(1, 0, 0)))
        // The neon loop runs NOW on the interaction layer (works while paused).
        #expect(!scene.interactions.isIdle)
        #expect(scene.entities.contains { $0.name == "highlight" })

        scene.update(deltaTime: 1.3) // past the 1.2 s default lap
        #expect(scene.interactions.isIdle)
        #expect(!scene.entities.contains { $0.name == "highlight" }) // border cleaned up
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
        chip.components[TapComponent.self] = TapComponent { _ in chipTapped = true }
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
