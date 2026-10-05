import Foundation

// One undo step per user gesture: a whole drag or move, a nudge, a typed time, I, O or Reset.
extension EditorModel {
    public var canUndo: Bool { history.canUndo }
    public var canRedo: Bool { history.canRedo }

    public func undo() {
        guard let previous = history.undo(from: selection) else { return }
        restore(previous)
    }

    public func redo() {
        guard let next = history.redo(from: selection) else { return }
        restore(next)
    }

    func beginGesture() {
        gestureStart = selection
    }

    /// Returns the selection from before the gesture when the gesture itself changed nothing,
    /// so a key-frame snap that follows can still become this gesture's undo step.
    func finishGesture() -> Selection? {
        guard let before = gestureStart else { return nil }
        gestureStart = nil
        return recordStep(from: before) ? nil : before
    }

    @discardableResult
    func recordStep(from before: Selection) -> Bool {
        guard history.record(from: before, to: selection) else { return false }
        onHistoryChange?(.recorded)
        return true
    }

    func recordingStep(_ change: () -> Void) {
        let before = selection
        change()
        recordStep(from: before)
    }

    func clearHistory() {
        history.removeAll()
        gestureStart = nil
        onHistoryChange?(.cleared)
    }

    private func restore(_ restored: Selection) {
        snapTask?.cancel()
        gestureStart = nil
        selection = restored
        restartPlaybackIfNeeded()
    }
}
