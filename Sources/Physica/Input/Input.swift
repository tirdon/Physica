// Input events delivered to scenes (world coordinates, z = 0 plane).
// The platform layer converts DOM pointer events — mouse, touch, and Apple
// Pencil all arrive through one unified API — and pushes them here; systems
// either consume the AsyncStream or poll `scene.pointer` (which also carries
// the device kind and pen pressure).

/// Which physical device produced a pointer event. Mirrors the DOM
/// `PointerEvent.pointerType` so the web layer maps it 1:1 — `pen` is an Apple
/// Pencil / stylus.
public enum PointerKind: Sendable, Equatable {
    case mouse, touch, pen
}

public enum InputEvent: Sendable, Equatable {
    case pointerDown(Position)
    case pointerMoved(Position)
    case pointerUp(Position)
    /// The OS/browser aborted the gesture — a system gesture took over, too many
    /// touch points landed, or the tab was backgrounded. Unlike `pointerUp`
    /// there is no drop point: the in-flight drag is cancelled, not completed.
    /// Routine on touch and pen, rare with a mouse.
    case pointerCancelled
    /// A double-click (DOM `dblclick`) / double-tap landed at this point. The
    /// platform layer leaves the browser to do the timing — the core carries no
    /// clock — so this arrives already debounced; host tests dispatch it
    /// directly. The single-click `onTap` (if any) has already fired first, in
    /// DOM order. Drives `DoubleTapComponent`.
    case doubleClick(Position)
    case keyDown(String)
    case keyUp(String)
}

public struct PointerState: Sendable, Equatable {
    public var position: Position = .zero
    public var isDown = false
    /// Device behind the latest event, so systems can treat pen, touch, and
    /// mouse differently. Defaults to `.mouse` (host tests, desktop).
    public var kind: PointerKind = .mouse
    /// Normalized 0...1 contact pressure (Apple Pencil / force touch); 0 for
    /// devices that don't report it and whenever the pointer is up.
    public var pressure: Real = 0
}

extension Scene {
    /// Buffered input stream; subscribe from systems or scripts.
    public func inputStream() -> AsyncStream<InputEvent> {
        let id = nextInputStreamID
        nextInputStreamID += 1
        return AsyncStream(bufferingPolicy: .bufferingNewest(64)) { continuation in
            inputContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in
                    self?.inputContinuations[id] = nil
                }
            }
        }
    }

    /// Platform layer entry point. The device kind and pen pressure stay at
    /// their current `pointer` values — desktop and host tests never set them,
    /// so they read as `.mouse` / 0. Use `dispatch(_:kind:pressure:)` to record
    /// touch/pen metadata alongside the event.
    public func dispatch(_ event: InputEvent) {
        switch event {
        case .pointerDown(let position):
            pointer.position = position
            pointer.isDown = true
        case .pointerMoved(let position):
            pointer.position = position
        case .pointerUp(let position):
            pointer.position = position
            pointer.isDown = false
            pointer.pressure = 0
        case .pointerCancelled:
            pointer.isDown = false
            pointer.pressure = 0
        case .doubleClick(let position):
            // A discrete click, not a press: position tracks, button state doesn't.
            pointer.position = position
        case .keyDown, .keyUp:
            break
        }
        // Drag-and-drop runs off raw events (pause-independent, unlike systems).
        drag.handle(event, in: self)
        for continuation in inputContinuations.values {
            continuation.yield(event)
        }
    }

    /// Platform entry that records the active device kind and pen pressure on
    /// `pointer` before dispatching the positional event — the web layer feeds
    /// these from the DOM `PointerEvent`. The bare `dispatch` zeroes pressure on
    /// up/cancel, so a released pointer always reports 0.
    public func dispatch(_ event: InputEvent, kind: PointerKind, pressure: Real = 0) {
        pointer.kind = kind
        pointer.pressure = pressure
        dispatch(event)
    }

    /// Converts normalized viewport coordinates (0...1, origin top-left) to the
    /// world point on the z = 0 plane.
    public func worldPosition(normalizedViewport point: SIMD2<Real>) -> Position {
        let frame = frameBounds
        return Position(
            frame.min.x + point.x * frame.size.x,
            frame.max.y - point.y * frame.size.y,
            0
        )
    }

    /// Index labels for the Shift debug overlay — cheap, no geometry flattening.
    /// One label per top-level entity at its center: a group (equation, plane,
    /// chip, plain `Group`, …) collapses to a single index rather than unfolding
    /// its children into a `0.0`/`6.0.0` thicket stacked near the group center.
    /// Invisible roots (faded to ~0 opacity; groups with nothing visible beneath
    /// them) get no label, and the index stays positional so the remaining
    /// siblings keep their numbering. Per-element detail (equation tokens, …)
    /// lives in the Option+Shift interactive overlay.
    public func collectDebugLabels() -> [DebugLabel] {
        var labels: [DebugLabel] = []
        for (index, root) in entities.enumerated() where debugLabelVisible(root) {
            labels.append(DebugLabel(text: "\(index)", worldPosition: root.center))
        }
        return labels
    }

    /// Labels for the Option+Shift overlay: only entities the user can grab or
    /// touch (draggable / drop target / tap / double-click / hover). Built for
    /// inspecting equation elements — every draggable token earns its own label
    /// instead of the equation group collapsing to a single index on the '='
    /// sign. Each label is a flat sequential number (no dotted path) carrying its
    /// interaction kind, which the overlay renders as a color rather than text.
    public func collectInteractiveDebugLabels() -> [DebugLabel] {
        var labels: [DebugLabel] = []
        func walk(_ entity: Entity) {
            if debugLabelVisible(entity), let kind = interactionKind(of: entity) {
                labels.append(DebugLabel(
                    text: "\(labels.count + 1)", worldPosition: entity.center, interaction: kind
                ))
            }
            if let group = entity as? Group {
                for child in group.children { walk(child) }
            }
        }
        for root in entities { walk(root) }
        return labels
    }

    /// World-space hit regions of every visible drop target, for the Option+Shift
    /// overlay to outline — so the user sees *where* a dragged token can land, not
    /// just that an entity accepts drops. Same walk as the interactive labels
    /// (groups recurse, invisible roots skipped); one box per `DropTargetComponent`
    /// (a group that is itself a target contributes its whole union bound).
    public func collectDropAreas() -> [Bounds] {
        var areas: [Bounds] = []
        func walk(_ entity: Entity) {
            if debugLabelVisible(entity), entity.components[DropTargetComponent.self] != nil {
                areas.append(entity.worldBounds)
            }
            if let group = entity as? Group {
                for child in group.children { walk(child) }
            }
        }
        for root in entities { walk(root) }
        return areas
    }

    /// A faded-to-invisible entity (or a group with nothing visible beneath it)
    /// gets no overlay label; a bare entity with no renderable component counts
    /// as visible.
    private func debugLabelVisible(_ entity: Entity) -> Bool {
        if let style = entity.components[RenderStyleComponent.self] {
            return style.opacity > 0.001
        }
        if let model = entity.components[ModelComponent.self] {
            return model.opacity > 0.001
        }
        if let group = entity as? Group {
            return group.children.contains { debugLabelVisible($0) }
        }
        return true  // bare entity — nothing renderable to be invisible
    }

    /// The entity's primary interaction kind (drag > drop > tap > double-click >
    /// hover when it carries several), or nil when it has none — which is how the
    /// interactive overlay skips it. The overlay colors the label by this.
    private func interactionKind(of entity: Entity) -> InteractionKind? {
        if entity.components[DraggableComponent.self] != nil { return .drag }
        if entity.components[DropTargetComponent.self] != nil { return .drop }
        if entity.components[TapComponent.self] != nil { return .tap }
        if entity.components[DoubleTapComponent.self] != nil { return .doubleClick }
        if entity.components[HoverComponent.self] != nil { return .hover }
        return nil
    }
}
