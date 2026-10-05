import Foundation
import Testing

@testable import TrimlineCore

@MainActor
@Suite struct EditorModelTests {
    private static let suffix = "clip"

    private func makeModel(engine: FakeEngine) -> EditorModel {
        EditorModel(clipSuffix: Self.suffix, opener: { _ throws(MediaOpenError) in engine })
    }

    private func openedModel(_ engine: FakeEngine) async throws -> EditorModel {
        let model = makeModel(engine: engine)
        model.open(engine.info.url)
        try #require(await waitUntil { model.phase == .ready })
        return model
    }

    // MARK: Opening

    @Test func openingSucceedsWithSelectionCoveringFile() async throws {
        let engine = FakeEngine.video(duration: 12)
        let model = try await openedModel(engine)
        #expect(model.info == engine.info)
        #expect(model.selection == Selection(duration: 12))
        #expect(model.playback === engine.player)
    }

    @Test func openingFailureIsReported() async throws {
        let url = URL(fileURLWithPath: "/tmp/broken.mp4")
        let model = EditorModel(clipSuffix: Self.suffix, opener: { _ throws(MediaOpenError) in throw .damaged })
        model.open(url)
        #expect(await waitUntil { model.phase == .failed(url, .damaged) })
        #expect(model.info == nil)
    }

    @Test func openingNewFileCancelsPrevious() async throws {
        let slow = FakeEngine.video(url: URL(fileURLWithPath: "/tmp/slow.mov"))
        let fast = FakeEngine.video(url: URL(fileURLWithPath: "/tmp/fast.mov"))
        let model = EditorModel(
            clipSuffix: Self.suffix,
            opener: { url throws(MediaOpenError) in
                if url == slow.info.url {
                    try? await Task.sleep(for: .seconds(2))
                    return slow
                }
                return fast
            })
        model.open(slow.info.url)
        model.open(fast.info.url)
        try #require(await waitUntil { model.phase == .ready })
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.info?.url == fast.info.url)
    }

    @Test func openingSeveralFilesRemembersCount() async throws {
        let engine = FakeEngine.video()
        let model = makeModel(engine: engine)
        let urls = ["a", "b", "c"].map { URL(fileURLWithPath: "/tmp/\($0).mov") }
        model.open(urls)
        #expect(model.requestedFileCount == 3)
        #expect(model.phase == .loading(urls[0]))
    }

    @Test func closingReturnsToEmptyWindow() async throws {
        let engine = FakeEngine.video()
        let model = makeModel(engine: engine)
        model.open(["a", "b"].map { URL(fileURLWithPath: "/tmp/\($0).mov") })
        try #require(await waitUntil { model.phase == .ready })
        model.closeCurrentFile()
        #expect(model.phase == .empty)
        #expect(model.info == nil)
        #expect(model.requestedFileCount == 0)
        #expect(engine.player.isClosed)
    }

    // MARK: Playback

    @Test func playbackStaysWithinSelection() async throws {
        let engine = FakeEngine.video()
        let model = try await openedModel(engine)
        model.exportMode = .precise
        model.setHandle(.start, to: 2.5)
        model.setHandle(.end, to: 5)
        model.togglePlayback()
        #expect(model.isPlaying)
        #expect(engine.player.plays.last == FakePlayback.Play(range: 2.5...5, looping: false))
        model.togglePlayback()
        #expect(!model.isPlaying)
    }

    @Test func stepMovesByFrames() async throws {
        let engine = FakeEngine.video(frameRate: 25)
        let model = try await openedModel(engine)
        model.seek(to: 1)
        model.step(frames: 3)
        #expect(abs(model.currentTime - 1.12) < 1e-9)
        model.step(frames: -1)
        #expect(abs(model.currentTime - 1.08) < 1e-9)
        #expect(engine.player.seeks.last?.precise == true)
    }

    @Test func scrubbingKeepsPlayheadUnderPointer() async throws {
        let engine = FakeEngine.video()
        let model = try await openedModel(engine)
        model.scrub(to: 3.3)
        engine.player.onTimeChange?(3)
        #expect(model.currentTime == 3.3)
        model.seek(to: 3.3)
        engine.player.onTimeChange?(3.4)
        #expect(model.currentTime == 3.4)
    }

    @Test func draggingHandlePreviewsEdgeAndKeepsPlayhead() async throws {
        let engine = FakeEngine.video()
        let model = try await openedModel(engine)
        model.exportMode = .precise
        model.seek(to: 2)
        model.beginDragging(.end)
        model.drag(.end, to: 6.6)
        #expect(engine.player.seeks.last == FakePlayback.Seek(time: 6.6, precise: false))
        engine.player.onTimeChange?(6)
        #expect(model.currentTime == 2)
        model.endDragging(.end)
        #expect(engine.player.seeks.last == FakePlayback.Seek(time: 2, precise: true))
    }

    @Test func seekingStaysWithinSelection() async throws {
        let engine = FakeEngine.video()
        let model = try await openedModel(engine)
        model.exportMode = .precise
        model.setHandle(.start, to: 2)
        model.setHandle(.end, to: 5)
        model.seek(to: 7)
        #expect(model.currentTime == 5)
        model.scrub(to: 1)
        #expect(model.currentTime == 2)
    }

    @Test func trimmingEdgesPushPlayhead() async throws {
        let engine = FakeEngine.video()
        let model = try await openedModel(engine)
        model.exportMode = .precise
        model.seek(to: 6)
        model.beginDragging(.end)
        model.drag(.end, to: 4)
        #expect(model.currentTime == 4)
        model.endDragging(.end)
        #expect(engine.player.seeks.last == FakePlayback.Seek(time: 4, precise: true))

        model.seek(to: 1)
        model.setHandle(.start, to: 2)
        #expect(model.currentTime == 2)
        #expect(engine.player.seeks.last == FakePlayback.Seek(time: 2, precise: true))
    }

    @Test func movingSelectionKeepsPlayhead() async throws {
        let engine = FakeEngine.video()
        let model = try await openedModel(engine)
        model.setHandle(.end, to: 4)
        model.seek(to: 3)
        model.moveSelection(by: 1)
        #expect(engine.player.seeks.last == FakePlayback.Seek(time: 1, precise: false))
        model.endMovingSelection()
        #expect(model.currentTime == 3)
        #expect(engine.player.seeks.last == FakePlayback.Seek(time: 3, precise: true))
    }

    // MARK: Selection

    @Test func draggedStartSnapsToKeyframeInFastMode() async throws {
        let engine = FakeEngine.video()
        let model = try await openedModel(engine)
        model.beginDragging(.start)
        model.drag(.start, to: 3.3)
        #expect(model.selection.start == 3.3)
        model.endDragging(.start)
        #expect(await waitUntil { model.selection.start == 2 })
    }

    @Test func draggedStartStaysExactForEditListContainers() async throws {
        let engine = FakeEngine.video(url: URL(fileURLWithPath: "/tmp/movie.mov"))
        let model = try await openedModel(engine)
        model.beginDragging(.start)
        model.drag(.start, to: 3.3)
        model.endDragging(.start)
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.selection.start == 3.3)
    }

    // Precise saving re-encodes the picture, so even an MKV start stays where it was dropped.
    @Test func preciseModeKeepsFFmpegOnlyVideoStartExact() async throws {
        let model = try await openedModel(FakeEngine.video())
        model.exportMode = .precise
        #expect(model.canSavePrecisely)
        model.beginDragging(.start)
        model.drag(.start, to: 3.3)
        model.endDragging(.start)
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.selection.start == 3.3)
        #expect(model.draggedHandle == nil)
    }

    @Test func preciseModeAppliesToNativeVideo() async throws {
        let model = try await openedModel(FakeEngine.video(url: URL(fileURLWithPath: "/tmp/movie.mp4")))
        #expect(model.canSavePrecisely)
        let audio = try await openedModel(FakeEngine.audio())
        #expect(!audio.canSavePrecisely)
    }

    // An edit list already makes a copy start on the exact frame, so re-encoding would gain nothing.
    @Test(arguments: ["mp4", "MOV", "m4v", "3gp"])
    func editListContainersSaveWithoutReencoding(_ fileExtension: String) async throws {
        let model = try await openedModel(FakeEngine.video(url: URL(fileURLWithPath: "/tmp/movie.\(fileExtension)")))
        model.exportMode = .precise
        #expect(model.effectiveExportMode == .fast)
    }

    @Test func otherContainersFollowTheSaveSetting() async throws {
        let model = try await openedModel(FakeEngine.video())
        model.exportMode = .precise
        #expect(model.effectiveExportMode == .precise)
        model.exportMode = .fast
        #expect(model.effectiveExportMode == .fast)
    }

    @Test func audioStartIsNeverSnapped() async throws {
        let engine = FakeEngine.audio()
        let model = try await openedModel(engine)
        model.beginDragging(.start)
        model.drag(.start, to: 3.3)
        model.endDragging(.start)
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.selection.start == 3.3)
    }

    @Test func markingUsesCurrentTime() async throws {
        let engine = FakeEngine.video()
        let model = try await openedModel(engine)
        model.exportMode = .precise
        model.seek(to: 1.5)
        model.markStart()
        model.seek(to: 6)
        model.markEnd()
        #expect(model.selection.range == 1.5...6)

        model.exportMode = .fast
        model.seek(to: 4.7)
        model.markStart()
        #expect(await waitUntil { model.selection.start == 4 })
    }

    @Test func resetSelectionCoversFile() async throws {
        let model = try await openedModel(FakeEngine.audio())
        model.setHandle(.start, to: 2)
        model.setHandle(.end, to: 3)
        model.resetSelection()
        #expect(model.selection.coversWholeFile)
    }
}
