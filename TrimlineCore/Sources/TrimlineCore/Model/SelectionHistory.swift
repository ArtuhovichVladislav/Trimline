import Foundation

/// Bounded undo and redo stacks of selection snapshots; each entry is the state before one user gesture.
public struct SelectionHistory: Sendable, Equatable {
    /// What the history observer is told about, so it can mirror steps into the system undo manager.
    public enum Change: Sendable {
        case recorded
        case cleared
    }

    public static let defaultLimit = 100

    public let limit: Int
    private var undoStack: [Selection] = []
    private var redoStack: [Selection] = []

    public init(limit: Int = Self.defaultLimit) {
        self.limit = max(1, limit)
    }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    /// Records the step from `previous` to `current`; returns `false` when nothing changed.
    @discardableResult
    public mutating func record(from previous: Selection, to current: Selection) -> Bool {
        guard previous != current else { return false }
        undoStack.append(previous)
        if undoStack.count > limit {
            undoStack.removeFirst(undoStack.count - limit)
        }
        redoStack.removeAll()
        return true
    }

    /// Returns the selection to restore, remembering `current` for redo.
    public mutating func undo(from current: Selection) -> Selection? {
        guard let previous = undoStack.popLast() else { return nil }
        redoStack.append(current)
        return previous
    }

    /// Returns the selection to restore, remembering `current` for undo.
    public mutating func redo(from current: Selection) -> Selection? {
        guard let next = redoStack.popLast() else { return nil }
        undoStack.append(current)
        return next
    }

    public mutating func removeAll() {
        undoStack.removeAll()
        redoStack.removeAll()
    }
}
