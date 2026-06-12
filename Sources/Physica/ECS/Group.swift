// Group — an entity that owns children and propagates its transform to them.

@MainActor
public protocol HasHierarchy: AnyObject {
    var children: [Entity] { get }
    func addChild(_ entity: Entity)
    func removeChild(_ entity: Entity)
}

@MainActor
open class Group: Entity, HasHierarchy {
    public private(set) var children: [Entity] = []

    public init(_ children: Entity...) {
        super.init()
        for child in children { addChild(child) }
    }

    public init(children: [Entity]) {
        super.init()
        for child in children { addChild(child) }
    }

    public override init() {
        super.init()
    }

    open func addChild(_ entity: Entity) {
        guard entity !== self, entity.parent !== self else { return }
        entity.parent = self
        // Transient bags (`Group(a, b).move(to: .bottom)`) never join a scene —
        // don't wipe the scene pointer of members that are already scene roots.
        if scene != nil { entity.scene = scene }
        children.append(entity)
        childrenDidChange()
    }

    open func removeChild(_ entity: Entity) {
        guard let index = children.firstIndex(where: { $0 === entity }) else { return }
        children.remove(at: index)
        entity.parent = nil
        entity.scene = nil
        childrenDidChange()
    }

    /// Child access by index, in add order: `plane.xLabels[0].color(.red)`,
    /// `plane.axes[0] === plane.xAxis`. Traps when out of range, like Array.
    public subscript(index: Int) -> Entity {
        children[index]
    }

    /// Hook for layout subclasses; called after the child list changes.
    open func childrenDidChange() {}

    /// Union of children bounds expressed in this group's local space.
    open override var localBounds: Bounds {
        var bounds = Bounds.empty
        for child in children {
            bounds = bounds.union(child.localBounds.transformed(by: child.transform))
        }
        return bounds
    }

    /// Depth-first traversal including self.
    public func traverse(_ visit: (Entity) -> Void) {
        visit(self)
        for child in children {
            if let group = child as? Group {
                group.traverse(visit)
            } else {
                visit(child)
            }
        }
    }
}
