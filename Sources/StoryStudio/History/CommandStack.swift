// CommandStack — snapshot-based undo/redo over the document.
//
// Because the document is a cheap `Equatable` value tree and every edit already
// triggers a full recompile, undo is simplest as whole-document snapshots rather
// than inverse commands: record the pre-edit state, and undo/redo swap states
// across two stacks. A `label` lets consecutive edits of the same kind coalesce
// into one undo entry (e.g. a drag), so a gesture is a single Cmd-Z.
//
// Platform-neutral and host-tested.

struct CommandStack<State> {
    private struct Entry {
        var state: State
        var label: String?
    }

    private var undoEntries: [Entry] = []
    private var redoStates: [State] = []
    private let limit: Int

    init(limit: Int = 100) {
        self.limit = limit
    }

    var canUndo: Bool { !undoEntries.isEmpty }
    var canRedo: Bool { !redoStates.isEmpty }

    /// Record `current` as a restore point before applying a mutation. When
    /// `coalescingLabel` matches the most recent record (and no undo/redo has
    /// happened since), the existing entry is kept so a burst of same-kind edits
    /// collapses to one undo step.
    mutating func record(_ current: State, coalescingLabel label: String? = nil) {
        if let label, let last = undoEntries.last, last.label == label {
            // Same gesture in progress — keep the earlier restore point.
        } else {
            undoEntries.append(Entry(state: current, label: label))
            if undoEntries.count > limit {
                undoEntries.removeFirst(undoEntries.count - limit)
            }
        }
        redoStates.removeAll()
    }

    /// Returns the state to restore (saving `current` for redo), or nil.
    mutating func undo(current: State) -> State? {
        guard let entry = undoEntries.popLast() else { return nil }
        redoStates.append(current)
        return entry.state
    }

    mutating func redo(current: State) -> State? {
        guard let next = redoStates.popLast() else { return nil }
        undoEntries.append(Entry(state: current, label: nil))
        return next
    }
}
