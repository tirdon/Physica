// The drag-and-drop component vocabulary, driven by `DragCoordinator`.
//
// Components are non-Sendable (the protocol has no Sendable bound), so they may
// store `@MainActor` closures — the same allowance UpdaterComponent relies on.
// The coordinator reads these straight off the entities it hit-tests; nothing
// here ticks on its own.

/// What a dragged token carries to a drop target. The game's terms travel as
/// `.expression`; an axis-projection operator as `.projection`; anything else
/// (buttons, chips) can use a free-form `.tag`.
public enum DragPayload: Sendable, Equatable {
    case expression(Expression)
    case projection(ProjectionAxis)
    case tag(String)

    public var debugLabel: String {
        switch self {
        case .expression(let e): return "expr(\(e.tex))"
        case .projection(let axis): return "proj(\(axis.label))"
        case .tag(let t): return "tag(\(t))"
        }
    }
}

/// A drop target's verdict on a payload it received.
public enum DropResolution: Sendable, Equatable {
    /// The target took the payload and owns any cleanup (removing the dragged
    /// proxy, snapping content into place). The coordinator does nothing more.
    case accepted
    /// The target refused — the coordinator shakes the target and snaps the
    /// dragged entity back home.
    case rejected
}

/// Marks an entity the user can pick up. With `makeDragProxy == nil` the entity
/// itself follows the pointer; otherwise a fresh proxy is spawned at grab and
/// the source stays put (the literals-from-text pattern).
public struct DraggableComponent: Component {
    public var isEnabled: Bool
    public var payload: DragPayload
    /// nil → drag the entity itself. Non-nil → called once at grab to build the
    /// entity that follows the pointer (the coordinator inserts it as the last
    /// scene root and removes it again if the drop is rejected).
    public var makeDragProxy: (@MainActor (Entity) -> Entity)?
    /// Whether a rejected / off-target drop animates back to the grab point.
    public var snapsBack: Bool
    public var onTap: (@MainActor (Entity) -> Void)?
    public var onDragBegan: (@MainActor (Entity) -> Void)?

    public init(
        payload: DragPayload,
        isEnabled: Bool = true,
        makeDragProxy: (@MainActor (Entity) -> Entity)? = nil,
        snapsBack: Bool = true,
        onTap: (@MainActor (Entity) -> Void)? = nil,
        onDragBegan: (@MainActor (Entity) -> Void)? = nil
    ) {
        self.payload = payload
        self.isEnabled = isEnabled
        self.makeDragProxy = makeDragProxy
        self.snapsBack = snapsBack
        self.onTap = onTap
        self.onDragBegan = onDragBegan
    }

    public var debugString: String {
        "Draggable(\(payload.debugLabel)\(isEnabled ? "" : ", disabled"))"
    }
}

/// Marks an entity that can receive dropped payloads.
public struct DropTargetComponent: Component {
    public var isEnabled: Bool
    /// nil → accept every payload. Otherwise consulted both for hover highlight
    /// and to decide whether a drop even reaches `onDrop`.
    public var accepts: (@MainActor (DragPayload) -> Bool)?
    /// nil → a drop that lands here is `.accepted` with no side effects. The
    /// second argument is the dragged entity, so the handler can read its
    /// transform or remove it.
    public var onDrop: (@MainActor (DragPayload, Entity) -> DropResolution)?
    /// Fired with `true` when a compatible drag enters and `false` when it leaves.
    public var onHoverChanged: (@MainActor (Bool) -> Void)?

    public init(
        isEnabled: Bool = true,
        accepts: (@MainActor (DragPayload) -> Bool)? = nil,
        onDrop: (@MainActor (DragPayload, Entity) -> DropResolution)? = nil,
        onHoverChanged: (@MainActor (Bool) -> Void)? = nil
    ) {
        self.isEnabled = isEnabled
        self.accepts = accepts
        self.onDrop = onDrop
        self.onHoverChanged = onHoverChanged
    }

    public var debugString: String { "DropTarget\(isEnabled ? "" : "(disabled)")" }
}

/// Tap-only handler (the choice chips). Works even while dragging is disabled,
/// so the user can still resolve a choice with `drag.isEnabled == false`.
public struct TapHandlerComponent: Component {
    public var isEnabled: Bool
    public var onTap: @MainActor (Entity) -> Void

    public init(isEnabled: Bool = true, onTap: @escaping @MainActor (Entity) -> Void) {
        self.isEnabled = isEnabled
        self.onTap = onTap
    }

    public var debugString: String { "TapHandler\(isEnabled ? "" : "(disabled)")" }
}

/// Tuning for the coordinator. Top-level (the AxisOptions precedent): nested
/// types inside a @MainActor class inherit its isolation.
public struct DragOptions: Sendable {
    /// Pointer travel (world units) below which a press is a tap, not a drag.
    public var tapSlop: Real
    /// How long an off-target / rejected drop takes to snap home.
    public var snapBackDuration: Duration

    public init(tapSlop: Real = 0.12, snapBackDuration: Duration = .seconds(0.25)) {
        self.tapSlop = tapSlop
        self.snapBackDuration = snapBackDuration
    }
}
