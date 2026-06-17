// Scene+HitTest — editor-facing geometry helpers (additive; nothing in the
// framework calls these — they exist for tools like Story Studio).
//
// `hitTest` is the painter's-order, last-painted-wins pick the editor uses for
// canvas selection — the same algorithm `DragCoordinator` runs internally,
// exposed for non-drag callers. `viewportPosition` is the inverse of
// `worldPosition(normalizedViewport:)` (Input/Input.swift), so the editor can
// place DOM overlays (selection box, handles) over a world-space entity.

extension Scene {
    /// The topmost entity — roots in painter order, group children depth-first,
    /// last match wins — whose world-XY bounds contain `point`. World z is ignored.
    public func hitTest(worldXY point: Position) -> Entity? {
        var result: Entity?
        func walk(_ entity: Entity) {
            let b = entity.worldBounds
            if !b.isEmpty,
               point.x >= b.min.x, point.x <= b.max.x,
               point.y >= b.min.y, point.y <= b.max.y {
                result = entity
            }
            if let group = entity as? Group {
                for child in group.children { walk(child) }
            }
        }
        for root in entities { walk(root) }
        return result
    }

    /// Every entity whose world-XY bounds contain `point`, in painter order (roots
    /// in insertion order, group children depth-first) — so the last element is the
    /// one `hitTest` would return. Unlike `hitTest` (last match only), this returns
    /// the full overlap stack, letting a tool disambiguate buried elements — e.g.
    /// Story Studio's ⌥-click radial picker. World z is ignored.
    public func hitTestAll(worldXY point: Position) -> [Entity] {
        var result: [Entity] = []
        func walk(_ entity: Entity) {
            let b = entity.worldBounds
            if !b.isEmpty,
               point.x >= b.min.x, point.x <= b.max.x,
               point.y >= b.min.y, point.y <= b.max.y {
                result.append(entity)
            }
            if let group = entity as? Group {
                for child in group.children { walk(child) }
            }
        }
        for root in entities { walk(root) }
        return result
    }

    /// Inverse of `worldPosition(normalizedViewport:)`: a world point → normalized
    /// viewport coordinates (0,0 = top-left of the frame, 1,1 = bottom-right).
    public func viewportPosition(world: Position) -> SIMD2<Real> {
        let frame = frameBounds
        let nx = frame.size.x != 0 ? (world.x - frame.min.x) / frame.size.x : 0
        let ny = frame.size.y != 0 ? (frame.max.y - world.y) / frame.size.y : 0
        return SIMD2(nx, ny)
    }
}
