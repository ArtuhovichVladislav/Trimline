import Foundation
import Testing

@testable import TrimlineCore

@MainActor
@Suite struct EditorModelHistoryTests {
    private func openedModel(_ engine: FakeEngine) async throws -> EditorModel {
        let model = EditorModel(clipSuffix: "clip", opener: { _ throws(MediaOpenError) in engine })
        model.open(engine.info.url)
        try #require(await waitUntil { model.phase == .ready })
        return model
    }

    @Test func wholeDragIsOneStep() async throws {
        let model = try await openedModel(FakeEngine.audio())
        model.beginDragging(.end)
        for end in [9.0, 8, 7, 6] {
            model.drag(.end, to: end)
        }
        model.endDragging(.end)

        model.undo()
        #expect(model.selection.coversWholeFile)
        #expect(!model.canUndo)
        model.redo()
        #expect(model.selection.end == 6)
    }

    @Test func dragWithoutMovementRecordsNothing() async throws {
        let model = try await openedModel(FakeEngine.audio())
        model.beginDragging(.start)
        model.endDragging(.start)
        #expect(!model.canUndo)
    }

    @Test func keyframeSnapMergesIntoDrag() async throws {
        let model = try await openedModel(FakeEngine.video())
        model.beginDragging(.start)
        model.drag(.start, to: 3.3)
        model.endDragging(.start)
        try #require(await waitUntil { model.selection.start == 2 })

        model.undo()
        #expect(model.selection.start == 0)
        #expect(!model.canUndo)
        model.redo()
        #expect(model.selection.start == 2)
    }

    @Test func snapAloneBecomesAStep() async throws {
        let model = try await openedModel(FakeEngine.video())
        model.setHandle(.start, to: 3.3)
        model.beginDragging(.start)
        model.endDragging(.start)
        try #require(await waitUntil { model.selection.start == 2 })

        model.undo()
        #expect(model.selection.start == 3.3)
        model.undo()
        #expect(model.selection.start == 0)
    }

    @Test func movingSelectionIsOneStep() async throws {
        let model = try await openedModel(FakeEngine.audio())
        model.setHandle(.end, to: 4)
        model.moveSelection(by: 1)
        model.moveSelection(by: 1)
        model.endMovingSelection()
        #expect(model.selection.range == 2...6)

        model.undo()
        #expect(model.selection.range == 0...4)
    }

    @Test func eachEditIsItsOwnStep() async throws {
        let model = try await openedModel(FakeEngine.audio())
        model.nudge(.end, seconds: -1)
        model.nudge(.end, frames: -1)
        model.seek(to: 2)
        model.markStart()
        model.seek(to: 5)
        model.markEnd()
        model.resetSelection()

        var undoCount = 0
        while model.canUndo {
            model.undo()
            undoCount += 1
        }
        #expect(undoCount == 5)
        #expect(model.selection.coversWholeFile)
    }

    @Test func openingFileClearsHistory() async throws {
        let engine = FakeEngine.audio()
        let model = try await openedModel(engine)
        var changes: [SelectionHistory.Change] = []
        model.onHistoryChange = { changes.append($0) }
        model.setHandle(.start, to: 1)
        model.undo()
        #expect(model.canRedo)

        model.open(engine.info.url)
        try #require(await waitUntil { model.phase == .ready })
        #expect(!model.canUndo)
        #expect(!model.canRedo)
        #expect(changes == [.recorded, .cleared])
    }

    @Test func undoKeepsPlaybackInsideRestoredClip() async throws {
        let engine = FakeEngine.audio()
        let model = try await openedModel(engine)
        model.setHandle(.end, to: 4)
        model.togglePlayback()
        model.undo()
        #expect(engine.player.plays.last?.range == 0...10)
    }
}
