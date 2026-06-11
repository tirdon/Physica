// Input events delivered to scenes (world coordinates, z = 0 plane).
// The platform layer converts DOM events and pushes them here; systems either
// consume the AsyncStream or poll `scene.pointer`.

public enum InputEvent: Sendable, Equatable {
    case pointerDown(Position)
    case pointerMoved(Position)
    case pointerUp(Position)
    case keyDown(String)
    case keyUp(String)
}

public struct PointerState: Sendable, Equatable {
    public var position: Position = .zero
    public var isDown = false
}

extension Scene {
    /// Buffered input stream; subscribe from systems or scripts.
    public func inputStream() -> AsyncStream<InputEvent> {
        let id = nextInputStreamID
        nextInputStreamID += 1
        return AsyncStream(bufferingPolicy: .bufferingNewest(64)) { continuation in
            inputContinuations[id] = continuation
            continuation.onTermination = { _ in
                Task { @MainActor [weak self] in
                    self?.inputContinuations[id] = nil
                }
            }
        }
    }

    /// Platform layer entry point.
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
        case .keyDown, .keyUp:
            break
        }
        for continuation in inputContinuations.values {
            continuation.yield(event)
        }
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
