import Foundation
import Testing

@testable import TrimlineCore

@Suite struct SelectionHistoryTests {
    private func selection(start: TimeInterval) -> Selection {
        Selection(duration: 10, start: start, end: 10)
    }

    @Test func undoAndRedoWalkTheSteps() {
        var history = SelectionHistory()
        history.record(from: selection(start: 0), to: selection(start: 1))
        history.record(from: selection(start: 1), to: selection(start: 2))

        let undone = [history.undo(from: selection(start: 2)), history.undo(from: selection(start: 1))]
        #expect(undone == [selection(start: 1), selection(start: 0)])
        #expect(!history.canUndo)
        let redone = history.redo(from: selection(start: 0))
        #expect(redone == selection(start: 1))
        #expect(history.canRedo)
    }

    @Test func unchangedSelectionIsNotAStep() {
        var history = SelectionHistory()
        let isRecorded = history.record(from: selection(start: 1), to: selection(start: 1))
        #expect(!isRecorded)
        #expect(!history.canUndo)
    }

    @Test func newStepDropsRedo() {
        var history = SelectionHistory()
        history.record(from: selection(start: 0), to: selection(start: 1))
        _ = history.undo(from: selection(start: 1))
        history.record(from: selection(start: 0), to: selection(start: 3))
        #expect(!history.canRedo)
    }

    @Test func oldestStepsFallOffAtLimit() {
        var history = SelectionHistory(limit: 2)
        for start in 0..<3 {
            history.record(from: selection(start: Double(start)), to: selection(start: Double(start + 1)))
        }
        let undone = [3.0, 2, 1].map { history.undo(from: selection(start: $0)) }
        #expect(undone == [selection(start: 2), selection(start: 1), nil])
    }

    @Test func defaultLimitIsOneHundred() {
        #expect(SelectionHistory().limit == 100)
    }
}
