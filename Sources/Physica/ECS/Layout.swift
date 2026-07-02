// Layouts — Groups that position their children: Row, Column, Grid.
//
// Layout is invalidation-driven (didSet on knobs, childrenDidChange, or manual
// invalidateLayout()); the scene runs pending layouts once per frame, children
// before parents so nested layouts compose.

import PhysicaMath
import PhysicaGeometry
import PhysicaTypesetting

@MainActor
open class Layout: Group {  // Group already provides HasHierarchy
    public var spacing: Real = 0.25 {
        didSet { invalidateLayout() }
    }

    /// Cross-axis alignment (Row: .top/.center/.bottom, Column: .left/.center/.right).
    public var alignment: Unit = .center {
        didSet { invalidateLayout() }
    }

    private var needsLayout = true

    public func invalidateLayout() {
        needsLayout = true
    }

    open override func childrenDidChange() {
        invalidateLayout()
    }

    func layoutIfNeeded() {
        guard needsLayout else { return }
        needsLayout = false
        performLayout()
    }

    /// Writes children's local transforms; subclasses implement.
    open func performLayout() {}

    /// Child bounds in this layout's space, ignoring the child's position
    /// (which the layout is about to assign).
    package func placementBounds(of child: Entity) -> Bounds {
        child.localBounds.transformed(
            by: Transform(orientation: child.orientation, scale: child.scale)
        )
    }
}

/// Horizontal arrangement, left → right, centered on the layout origin.
@MainActor
public final class Row: Layout {
    public override func performLayout() {
        guard !children.isEmpty else { return }
        let bounds = children.map { placementBounds(of: $0) }
        let totalWidth = bounds.reduce(0) { $0 + $1.size.x } + spacing * Real(children.count - 1)
        let halfHeight = bounds.map { $0.size.y / 2 }.max() ?? 0

        var cursor = -totalWidth / 2
        for (child, box) in zip(children, bounds) {
            child.position.x = cursor + box.size.x / 2 - box.center.x
            switch alignment {
            case .top, .topLeft, .topRight:
                child.position.y = halfHeight - box.max.y
            case .bottom, .bottomLeft, .bottomRight:
                child.position.y = -halfHeight - box.min.y
            default:
                child.position.y = -box.center.y
            }
            cursor += box.size.x + spacing
        }
    }
}

/// Vertical arrangement, top → bottom, centered on the layout origin.
@MainActor
public final class Column: Layout {
    public override func performLayout() {
        guard !children.isEmpty else { return }
        let bounds = children.map { placementBounds(of: $0) }
        let totalHeight = bounds.reduce(0) { $0 + $1.size.y } + spacing * Real(children.count - 1)
        let halfWidth = bounds.map { $0.size.x / 2 }.max() ?? 0

        var cursor = totalHeight / 2
        for (child, box) in zip(children, bounds) {
            child.position.y = cursor - box.size.y / 2 - box.center.y
            switch alignment {
            case .left, .topLeft, .bottomLeft:
                child.position.x = -halfWidth - box.min.x
            case .right, .topRight, .bottomRight:
                child.position.x = halfWidth - box.max.x
            default:
                child.position.x = -box.center.x
            }
            cursor -= box.size.y + spacing
        }
    }
}

/// Fixed-column grid, row-major, uniform cells sized to the largest child.
@MainActor
public final class Grid: Layout {
    public var columns: Int = 2 {
        didSet { invalidateLayout() }
    }

    public init(columns: Int = 2, _ children: Entity...) {
        self.columns = columns
        super.init(children: children)
    }

    public override init() {
        super.init()
    }

    public override init(children: [Entity]) {
        super.init(children: children)
    }

    public override func performLayout() {
        guard !children.isEmpty, columns > 0 else { return }
        let bounds = children.map { placementBounds(of: $0) }
        let cellWidth = bounds.map { $0.size.x }.max() ?? 0
        let cellHeight = bounds.map { $0.size.y }.max() ?? 0
        let rows = (children.count + columns - 1) / columns

        let strideX = cellWidth + spacing
        let strideY = cellHeight + spacing
        let originX = -strideX * Real(columns - 1) / 2
        let originY = strideY * Real(rows - 1) / 2

        for (index, (child, box)) in zip(children, bounds).enumerated() {
            let column = index % columns
            let row = index / columns
            child.position.x = originX + strideX * Real(column) - box.center.x
            child.position.y = originY - strideY * Real(row) - box.center.y
        }
    }
}

extension Scene {
    /// Runs pending layouts depth-first (children first) once per frame.
    func runLayouts() {
        func walk(_ entity: Entity) {
            if let group = entity as? Group {
                for child in group.children { walk(child) }
            }
            if let layout = entity as? Layout {
                layout.layoutIfNeeded()
            }
        }
        for root in entities { walk(root) }
    }
}
