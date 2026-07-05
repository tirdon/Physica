// DragCoordinator — the pointer state machine behind drag-and-drop.
//
// Event-driven from `Scene.dispatch`, NOT a registry System: systems are
// skipped while `timeline.isPaused`, and story mode rests paused at every step
// boundary — exactly when the user reaches in to drag. Driving it from dispatch
// makes drags pause-independent and host-testable with no ticking at all (snap
// back is the only animated part, and that rides the InteractionRunner).
//
// press → (move past slop) → drag → drop. A press that releases within the slop
// is a tap. Hit-testing is painter's order, last-painted-wins, matching the
// renderer so the entity on top is the one grabbed.

import PhysicaFoundation
import PhysicaTypesetting

@MainActor
public final class DragCoordinator {
    public var options = DragOptions()
    /// Gates draggable grabs (the game turns this off while choice chips are up).
    /// Tap handlers stay live regardless, so chips remain tappable.
    public var isEnabled = true

    private enum Phase {
        case idle
        case pressed(source: Entity, start: Position)
        case dragging(ActiveDrag)
    }

    private struct ActiveDrag {
        let source: Entity
        /// `source` itself, or a spawned proxy that follows the pointer.
        let dragged: Entity
        let isProxy: Bool
        let payload: DragPayload
        /// dragged.position − pointer at promotion, kept constant while dragging.
        let grabOffset: Position
        let homeTransform: Transform
        var hovered: Entity?
    }

    private var phase: Phase = .idle

    /// The `HoverComponent` entity the bare pointer currently rests over (no
    /// button held). Distinct from `ActiveDrag.hovered`, which is the drop
    /// target under an in-flight drag.
    private var hoverTarget: Entity?

    public init() {}

    // MARK: Event entry (Scene.dispatch)

    func handle(_ event: InputEvent, in scene: Scene) {
        switch event {
        case .pointerDown(let p): beginPress(at: p, in: scene)
        case .pointerMoved(let p): updateDrag(at: p, in: scene)
        case .pointerUp(let p): endDrag(at: p, in: scene)
        case .pointerCancelled: cancelActive(in: scene)
        case .doubleClick(let p): deliverDoubleClick(at: p, in: scene)
        case .keyDown, .keyUp: break
        }
    }

    // MARK: Phases

    private func beginPress(at pointer: Position, in scene: Scene) {
        // Tap handlers (chips) respond even while dragging is disabled;
        // draggables only when the coordinator is enabled.
        let hit = topmostHit(at: pointer, in: scene) { entity in
            if let tap = entity.components[TapComponent.self], tap.isEnabled { return true }
            if isEnabled, let drag = entity.components[DraggableComponent.self], drag.isEnabled { return true }
            return false
        }
        phase = hit.map { .pressed(source: $0, start: pointer) } ?? .idle
    }

    private func updateDrag(at pointer: Position, in scene: Scene) {
        switch phase {
        case .idle:
            // No gesture: the bare pointer is just hovering. Keep HoverComponents
            // in sync. (Mid-gesture moves below own hover via the drop target.)
            updateHoverTarget(at: pointer, in: scene)
        case .pressed(let source, let start):
            guard movedPastSlop(from: start, to: pointer) else { return }
            // Only a draggable promotes; a tap handler dragged past slop is just
            // a cancelled tap. Anchor the grab to `start` (the press point), not
            // the post-slop `pointer`: the offset must be where the finger first
            // touched relative to the entity, so the slop travel — up to a whole
            // flick on a fast first move — doesn't leak in and push the payload
            // away from the pointer.
            if isEnabled, let draggable = source.components[DraggableComponent.self], draggable.isEnabled {
                promote(source: source, draggable: draggable, grabbedAt: start, pointer: pointer, in: scene)
            } else {
                phase = .idle
            }
        case .dragging(var active):
            active.dragged.position = pointer + active.grabOffset
            updateHover(&active, pointer: pointer, in: scene)
            phase = .dragging(active)
        }
    }

    private func endDrag(at pointer: Position, in scene: Scene) {
        switch phase {
        case .idle:
            break
        case .pressed(let source, let start):
            phase = .idle
            if !movedPastSlop(from: start, to: pointer) { deliverTap(to: source, in: scene) }
        case .dragging(var active):
            phase = .idle
            clearHover(&active)
            let target = topmostHit(at: pointer, in: scene) { entity in
                entity !== active.dragged && acceptsDrop(entity, active.payload)
            }
            if let target, let drop = target.components[DropTargetComponent.self] {
                let resolution = drop.onDrop?(active.payload, active.dragged) ?? .accepted
                switch resolution {
                case .accepted:
                    break  // handler owns cleanup
                case .rejected:
                    scene.interact(.shake(target), onInterrupt: .complete)
                    returnHome(active, in: scene)
                }
            } else {
                returnHome(active, in: scene)
            }
        }
        // Re-evaluate the bare-pointer hover at the release point — a click or a
        // drop can land the cursor on a different HoverComponent than before.
        updateHoverTarget(at: pointer, in: scene)
    }

    // MARK: Public controls

    /// Abort any in-flight gesture instantly (no snap-back animation): proxies
    /// are removed, in-place drags restored. The story player calls this on
    /// slide changes, and `dispatch` routes a `pointerCancelled` here, so a
    /// system-cancelled touch/pen gesture never strands a token mid-air.
    public func cancelActive(in scene: Scene) {
        switch phase {
        case .idle, .pressed:
            phase = .idle
        case .dragging(var active):
            phase = .idle
            clearHover(&active)
            if active.isProxy {
                scene.detach(active.dragged)
            } else {
                active.dragged.transform = active.homeTransform
            }
        }
        // Drop any standing bare-pointer hover too — a slide change (the story
        // player's caller) resets every interaction affordance.
        setHoverTarget(nil)
    }

    /// The bare pointer left the interactive surface (the mouse slid off the
    /// canvas) while idle — drop any standing `HoverComponent` highlight so it
    /// doesn't stick. A captured drag survives off-canvas, so this no-ops unless
    /// idle; the web shell calls it on `pointerleave`.
    public func clearHover() {
        if case .idle = phase { setHoverTarget(nil) }
    }

    /// Whether a draggable sits under this world point — the web shell consults
    /// this per pointerdown to flip `touch-action` so touch scrolling still
    /// works over the pinned canvas everywhere else.
    public func hitTestDraggable(at point: Position, in scene: Scene) -> Bool {
        guard isEnabled else { return false }
        return topmostHit(at: point, in: scene) {
            $0.components[DraggableComponent.self]?.isEnabled ?? false
        } != nil
    }

    public var debugString: String {
        switch phase {
        case .idle:
            return "drag idle"
        case .pressed(let source, _):
            return "drag pressed \(name(of: source))"
        case .dragging(let active):
            let over = active.hovered.map { name(of: $0) } ?? "—"
            return "drag \(name(of: active.dragged)) over \(over)"
        }
    }

    // MARK: Internals

    private func promote(source: Entity, draggable: DraggableComponent, grabbedAt grab: Position, pointer: Position, in scene: Scene) {
        let dragged: Entity
        let isProxy: Bool
        if let make = draggable.makeDragProxy {
            let proxy = make(source)
            scene.insert(proxy)  // last root → painter's top
            dragged = proxy
            isProxy = true
        } else {
            dragged = source
            isProxy = false
        }
        draggable.onDragBegan?(source)
        // Offset from the press point, so the grabbed spot stays under the
        // pointer; the home transform is captured before the first follow move.
        let grabOffset = dragged.position - grab
        let homeTransform = dragged.transform
        // Honor the move that crossed the slop right away — otherwise the entity
        // sits a frame behind on a fast flick.
        dragged.position = pointer + grabOffset
        var active = ActiveDrag(
            source: source, dragged: dragged, isProxy: isProxy, payload: draggable.payload,
            grabOffset: grabOffset, homeTransform: homeTransform, hovered: nil
        )
        updateHover(&active, pointer: pointer, in: scene)
        phase = .dragging(active)
    }

    private func returnHome(_ active: ActiveDrag, in scene: Scene) {
        let snapsBack = active.source.components[DraggableComponent.self]?.snapsBack ?? true
        let dragged = active.dragged
        let isProxy = active.isProxy
        guard snapsBack else {
            if isProxy { scene.detach(dragged) }
            return
        }
        scene.interact(
            dragged.move(to: active.homeTransform.position),
            for: options.snapBackDuration,
            onInterrupt: .complete,
            completion: { [weak scene] in
                if isProxy { scene?.detach(dragged) }
            }
        )
    }

    /// Runs `body` with the runner's handler-owner set to `owner`, so any
    /// interaction the handler starts defaults to being owned by `owner` (no
    /// explicit `owner:` at the call site). Saves/restores so nesting is safe.
    private func withHandlerOwner(_ owner: Entity, in scene: Scene, _ body: () -> Void) {
        let previous = scene.interactions.handlerOwner
        scene.interactions.handlerOwner = owner
        defer { scene.interactions.handlerOwner = previous }
        body()
    }

    private func deliverTap(to entity: Entity, in scene: Scene) {
        if let tap = entity.components[TapComponent.self], tap.isEnabled {
            withHandlerOwner(entity, in: scene) { tap.onTap(scene, entity) }
        } else if let draggable = entity.components[DraggableComponent.self], draggable.isEnabled {
            draggable.onTap?(entity)
        }
    }

    /// Fires the topmost `DoubleTapComponent` under the point. Stays live even
    /// while `isEnabled == false` (chips/buttons resolve choices) — a discrete
    /// click never disturbs the single-pointer drag state machine.
    private func deliverDoubleClick(at pointer: Position, in scene: Scene) {
        let hit = topmostHit(at: pointer, in: scene) { entity in
            entity.components[DoubleTapComponent.self]?.isEnabled ?? false
        }
        if let hit, let dbl = hit.components[DoubleTapComponent.self], dbl.isEnabled {
            withHandlerOwner(hit, in: scene) { dbl.onDoubleTap(scene, hit) }
        }
    }

    /// Recompute which `HoverComponent` the bare pointer rests over and fire
    /// enter/leave on the difference.
    private func updateHoverTarget(at pointer: Position, in scene: Scene) {
        let next = topmostHit(at: pointer, in: scene) { entity in
            entity.components[HoverComponent.self]?.isEnabled ?? false
        }
        setHoverTarget(next)
    }

    private func setHoverTarget(_ next: Entity?) {
        guard next !== hoverTarget else { return }
        if let old = hoverTarget, let hover = old.components[HoverComponent.self] {
            hover.onHoverChanged(old, false)
        }
        if let new = next, let hover = new.components[HoverComponent.self] {
            hover.onHoverChanged(new, true)
        }
        hoverTarget = next
    }

    private func updateHover(_ active: inout ActiveDrag, pointer: Position, in scene: Scene) {
        let next = topmostHit(at: pointer, in: scene) { entity in
            entity !== active.dragged && acceptsDrop(entity, active.payload)
        }
        guard next !== active.hovered else { return }
        active.hovered?.components[DropTargetComponent.self]?.onHoverChanged?(false)
        next?.components[DropTargetComponent.self]?.onHoverChanged?(true)
        active.hovered = next
    }

    private func clearHover(_ active: inout ActiveDrag) {
        active.hovered?.components[DropTargetComponent.self]?.onHoverChanged?(false)
        active.hovered = nil
    }

    private func acceptsDrop(_ entity: Entity, _ payload: DragPayload) -> Bool {
        guard let target = entity.components[DropTargetComponent.self], target.isEnabled else { return false }
        return target.accepts?(payload) ?? true
    }

    private func movedPastSlop(from start: Position, to end: Position) -> Bool {
        let dx = end.x - start.x
        let dy = end.y - start.y
        return dx * dx + dy * dy > options.tapSlop * options.tapSlop
    }

    /// Last entity in painter's order (roots in order, group children
    /// depth-first) whose world XY bounds contain the point and that matches.
    private func topmostHit(at point: Position, in scene: Scene, where matches: (Entity) -> Bool) -> Entity? {
        var result: Entity?
        func walk(_ entity: Entity) {
            if matches(entity), containsXY(entity, point) { result = entity }
            if let group = entity as? Group {
                for child in group.children { walk(child) }
            }
        }
        for root in scene.entities { walk(root) }
        return result
    }

    private func containsXY(_ entity: Entity, _ point: Position) -> Bool {
        let b = entity.worldBounds
        guard !b.isEmpty else { return false }
        return point.x >= b.min.x && point.x <= b.max.x && point.y >= b.min.y && point.y <= b.max.y
    }
}
