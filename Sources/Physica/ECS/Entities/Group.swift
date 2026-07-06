// Group — an entity that owns children and propagates its transform to them.

import PhysicaFoundation
import PhysicaTypesetting

@MainActor
public protocol HasHierarchy: AnyObject {
    var children: [Entity] { get }
    func addChild(_ entity: Entity)
    func removeChild(_ entity: Entity)
}

/// An entity that belongs to a host group rather than the scene's root list:
/// `Scene.insert` attaches it to its anchor instead of rooting it (plots
/// attach to their plane, so board transforms and rescales carry them).
@MainActor
public protocol GroupAnchored: AnyObject {
    var anchorGroup: Group { get }
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

    /// Re-inserts a child at a specific slot (painter's order among siblings) —
    /// scrub rewinds restoring a removed child use this to land it back where
    /// it was. (`package`: the chart element tracks in PhysicaCharts restore
    /// their removed bars/wedges through it too.)
    package func insertChild(_ entity: Entity, at index: Int) {
        guard entity !== self, entity.parent !== self else { return }
        entity.parent = self
        if scene != nil { entity.scene = scene }
        children.insert(entity, at: Swift.min(index, children.count))
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
