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
    /// Invisible entities (faded to ~0 opacity; groups with nothing visible
    /// beneath them) get no label. Index paths stay positional, so visible
    /// siblings keep their numbering.
    public func collectDebugLabels() -> [DebugLabel] {
        func isVisible(_ entity: Entity) -> Bool {
            if let style = entity.components[RenderStyleComponent.self] {
                return style.opacity > 0.001
            }
            if let model = entity.components[ModelComponent.self] {
                return model.opacity > 0.001
            }
            if let group = entity as? Group {
                return group.children.contains { isVisible($0) }
            }
            return true  // bare entity — nothing renderable to be invisible
        }

        var labels: [DebugLabel] = []
        func walk(_ entity: Entity, _ path: String) {
            if isVisible(entity) {
                labels.append(DebugLabel(text: path, worldPosition: entity.center))
            }
            if let group = entity as? Group {
                for (index, child) in group.children.enumerated() {
                    walk(child, "\(path).\(index)")
                }
            }
        }
        for (index, root) in entities.enumerated() {
            walk(root, "\(index)")
        }
        return labels
    }
}
