import CoreGraphics
import Foundation
import ImageIO
import Testing

@testable import TrimlineCore

/// A FakeEngine whose frame takes `delay` to render, or never comes.
private final class FrameEngine: MediaEngine {
    let base: FakeEngine
    let delay: Duration
    let rendersFrames: Bool

    init(base: FakeEngine, delay: Duration = .zero, rendersFrames: Bool = true) {
        self.base = base
        self.delay = delay
        self.rendersFrames = rendersFrames
    }

    var info: MediaInfo { base.info }

    @MainActor func makePlayback() -> any PlaybackController { base.makePlayback() }

    func thumbnails(count: Int, height: Int, in range: ClosedRange<TimeInterval>) -> AsyncStream<Thumbnail> {
        base.thumbnails(count: count, height: height, in: range)
    }

    func peaks(buckets: Int) -> AsyncStream<PeakChunk> { base.peaks(buckets: buckets) }

    func keyframe(atOrBefore time: TimeInterval) async -> TimeInterval { await base.keyframe(atOrBefore: time) }

    func frameImage(at time: TimeInterval) async -> CGImage? {
        try? await Task.sleep(for: delay)
        guard rendersFrames, !Task.isCancelled else { return nil }
        return await base.frameImage(at: time)
    }
}

@MainActor
@Suite struct EditorModelFrameTests {
    private func openedModel(_ engine: any MediaEngine) async throws -> EditorModel {
        let model = EditorModel(clipSuffix: "clip", opener: { _ throws(MediaOpenError) in engine })
        model.frameNaming = FrameNaming(word: "frame", locale: Locale(identifier: "en_US"))
        model.open(engine.info.url)
        try #require(await waitUntil { model.phase == .ready })
        return model
    }

    private func videoInFolder(delay: Duration = .zero, rendersFrames: Bool = true) throws -> (FrameEngine, URL) {
        let folder = try TestMedia.makeTemporaryFolder()
        let base = FakeEngine.video(url: folder.appendingPathComponent("movie.mkv"), duration: 100)
        return (FrameEngine(base: base, delay: delay, rendersFrames: rendersFrames), folder)
    }

    private func finished(_ model: EditorModel) async -> Bool {
        await waitUntil {
            switch model.frameExport {
            case .saved, .copied, .failed, .choosingDestination: true
            case .idle, .working: false
            }
        }
    }

    @Test func savesFrameNextToOriginal() async throws {
        let (engine, folder) = try videoInFolder()
        let model = try await openedModel(engine)
        model.seek(to: 83.45)

        model.saveFrame()
        #expect(model.frameExport == .working(.save))
        #expect(!model.canExportFrame)
        try #require(await finished(model))

        let expected = folder.appendingPathComponent("movie (frame 01-23.45).png")
        #expect(model.frameExport == .saved(expected))
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == [expected.lastPathComponent])
        #expect(model.canExportFrame)
    }

    @Test func secondFrameAtSameTimeGetsNumber() async throws {
        let (engine, folder) = try videoInFolder()
        let model = try await openedModel(engine)
        model.seek(to: 2)
        model.saveFrame()
        try #require(await finished(model))
        model.saveFrame()
        try #require(
            await waitUntil {
                model.frameExport == .saved(folder.appendingPathComponent("movie (frame 00-02.00 2).png"))
            })
    }

    @Test func asksForDestinationWhenSettingsSaySo() async throws {
        let (engine, folder) = try videoInFolder()
        let model = try await openedModel(engine)
        model.alwaysAsksForDestination = true

        model.saveFrame()
        try #require(await finished(model))
        let proposed = folder.appendingPathComponent("movie (frame 00-00.00).png")
        #expect(
            model.frameExport == .choosingDestination(FrameSaveProposal(destination: proposed, folderIsWritable: true)))
        #expect(!model.canExportFrame)

        let chosen = folder.appendingPathComponent("Chosen.png")
        model.confirmFrameSave(to: chosen)
        try #require(await waitUntil { model.frameExport == .saved(chosen) })
        #expect(FileManager.default.fileExists(atPath: chosen.path))
    }

    @Test func cancellingSavePanelWritesNothing() async throws {
        let (engine, folder) = try videoInFolder()
        let model = try await openedModel(engine)
        model.alwaysAsksForDestination = true
        model.saveFrame()
        try #require(await finished(model))

        model.cancelFrameSave()
        #expect(model.frameExport == .idle)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
    }

    @Test func readOnlyFolderAsksForDestination() async throws {
        let (engine, folder) = try videoInFolder()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
        let model = try await openedModel(engine)

        model.saveFrame()
        try #require(await finished(model))
        guard case .choosingDestination(let proposal) = model.frameExport else {
            Issue.record("expected a save panel, got \(model.frameExport)")
            return
        }
        #expect(!proposal.folderIsWritable)
    }

    @Test func existingDestinationIsReportedAndKept() async throws {
        let (engine, folder) = try videoInFolder()
        let model = try await openedModel(engine)
        model.alwaysAsksForDestination = true
        let existing = folder.appendingPathComponent("Existing.png")
        try Data("keep".utf8).write(to: existing)

        model.saveFrame()
        try #require(await finished(model))
        model.confirmFrameSave(to: existing)
        try #require(await waitUntil { model.frameExport == .failed(.save, .destinationExists) })
        #expect(try Data(contentsOf: existing) == Data("keep".utf8))
    }

    @Test func undecodableFrameFails() async throws {
        let (engine, _) = try videoInFolder(rendersFrames: false)
        let model = try await openedModel(engine)
        model.saveFrame()
        try #require(await waitUntil { model.frameExport == .failed(.save, .frameUnavailable) })
        model.dismissFrameResult()
        #expect(model.frameExport == .idle)
    }

    @Test func copiesPNGToPasteboard() async throws {
        let (engine, _) = try videoInFolder()
        let model = try await openedModel(engine)
        var copied: FramePicture?

        model.copyFrame { picture in
            copied = picture
            return true
        }
        #expect(model.frameExport == .working(.copy))
        try #require(await waitUntil { model.frameExport == .copied })
        let picture = try #require(copied)
        let source = try #require(CGImageSourceCreateWithData(picture.pngData as CFData, nil))
        #expect(CGImageSourceGetType(source) as String? == "public.png")
        #expect(picture.image.width == 32)
    }

    @Test func refusedPasteboardFails() async throws {
        let (engine, _) = try videoInFolder()
        let model = try await openedModel(engine)
        model.copyFrame { _ in false }
        try #require(await waitUntil { model.frameExport == .failed(.copy, .pasteboardUnavailable) })
    }

    @Test func changingFileCancelsRendering() async throws {
        let (engine, folder) = try videoInFolder(delay: .milliseconds(300))
        let model = try await openedModel(engine)
        model.saveFrame()
        #expect(model.frameExport == .working(.save))

        model.closeCurrentFile()
        #expect(model.frameExport == .idle)
        try await Task.sleep(for: .milliseconds(600))
        #expect(model.frameExport == .idle)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
    }

    @Test func savingPausesPlaybackOnShownFrame() async throws {
        let (engine, _) = try videoInFolder()
        let model = try await openedModel(engine)
        model.togglePlayback()
        #expect(model.isPlaying)

        model.saveFrame()
        #expect(!model.isPlaying)
        try #require(await finished(model))
    }

    @Test func audioHasNoFrameToSave() async throws {
        let model = try await openedModel(FakeEngine.audio())
        #expect(!model.canExportFrame)
        model.saveFrame()
        model.copyFrame { _ in true }
        #expect(model.frameExport == .idle)
    }
}
