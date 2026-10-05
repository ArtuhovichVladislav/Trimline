import AVFoundation
import Foundation
import Testing

@testable import TrimlineCore

@MainActor
@Suite struct EditorModelContentTests {
    private func openedModel(_ engine: FakeEngine) async throws -> EditorModel {
        let model = EditorModel(clipSuffix: "clip", opener: { _ throws(MediaOpenError) in engine })
        model.open(engine.info.url)
        try #require(await waitUntil { model.phase == .ready })
        return model
    }

    private func proposal(of model: EditorModel) async throws -> SaveProposal {
        try #require(await waitUntil { model.isSaveProposalCurrent })
        guard case .confirming(let proposal) = model.saveState else { throw CancellationError() }
        return proposal
    }

    // An MP4 with H.264 and AAC, so the sound's own format is known.
    private func openedMP4() async throws -> EditorModel {
        let folder = try TestMedia.makeTemporaryFolder()
        let source = folder.appendingPathComponent("movie.mp4")
        try FileManager.default.copyItem(at: try await TestMedia.video(.init(fileType: .mp4)), to: source)
        let engine = FakeEngine.video(url: source, duration: 4, frameRate: 30, keyframes: [0, 1, 2, 3])
        return try await openedModel(engine)
    }

    @Test(arguments: [
        (ExportContent.videoAndSound, "movie (clip).mp4"), (.videoOnly, "movie (clip).mp4"),
        (.soundOnly, "movie (clip).m4a"),
    ])
    func destinationFollowsTheContent(_ content: ExportContent, expected: String) async throws {
        let model = try await openedMP4()
        model.exportContent = content
        model.prepareSave()
        let proposal = try await proposal(of: model)
        #expect(proposal.destination.lastPathComponent == expected)
        #expect(proposal.content == content)
        #expect(!proposal.changesContainer)
    }

    @Test func soundOnlyStartsWhereAskedAndIsAlwaysFast() async throws {
        let model = try await openedModel(FakeEngine.video())
        model.exportMode = .precise
        model.exportContent = .soundOnly
        #expect(model.effectiveExportMode == .fast)
        model.setHandle(.start, to: 3.3)

        model.prepareSave()
        let proposal = try await proposal(of: model)
        #expect(proposal.range.lowerBound == 3.3)
        #expect(proposal.mode == .fast)
        #expect(proposal.destination.pathExtension == "mka")

        model.exportContent = .videoOnly
        #expect(await waitUntil { (try? self.current(model).content) == .videoOnly })
        #expect(try current(model).mode == .precise)
        #expect(try current(model).range.lowerBound == 3.3)
    }

    @Test func videoOnlyStartsOnKeyframeInFastMode() async throws {
        let model = try await openedModel(FakeEngine.video())
        model.exportContent = .videoOnly
        model.setHandle(.start, to: 3.3)
        model.prepareSave()
        #expect(try await proposal(of: model).range.lowerBound == 2)
    }

    @Test func staleContentCannotBeSaved() async throws {
        let model = try await openedMP4()
        model.prepareSave()
        let both = try await proposal(of: model)

        model.exportContent = .soundOnly
        #expect(!model.isSaveProposalCurrent)
        model.confirmSave(to: both.destination)
        #expect(model.saveState == .confirming(both))
        #expect(await waitUntil { (try? self.current(model).content) == .soundOnly })
        #expect(model.isSaveProposalCurrent)
        #expect(try current(model).destination.pathExtension == "m4a")
    }

    @Test func openingAFileResetsTheContent() async throws {
        let engine = FakeEngine.video()
        let model = try await openedModel(engine)
        model.exportContent = .soundOnly
        model.open(engine.info.url)
        #expect(model.exportContent == .videoAndSound)
        model.exportContent = .videoOnly
        model.closeCurrentFile()
        #expect(model.exportContent == .videoAndSound)
    }

    @Test func choiceNeedsAVideoWithSound() async throws {
        let silent = try await openedModel(FakeEngine.video(hasAudio: false))
        #expect(!silent.canChooseExportContent)
        silent.exportContent = .soundOnly
        #expect(silent.effectiveExportContent == .videoAndSound)

        let audio = try await openedModel(FakeEngine.audio())
        #expect(!audio.canChooseExportContent)
        audio.exportContent = .videoOnly
        #expect(audio.effectiveExportContent == .videoAndSound)

        let video = try await openedModel(FakeEngine.video())
        #expect(video.canChooseExportContent)
        video.exportContent = .soundOnly
        #expect(video.effectiveExportContent == .soundOnly)
    }

    @Test func sizeEstimateFollowsTheContent() {
        let info = FakeEngine.video().info
        let whole = info.estimatedClipSize(length: 8)
        #expect(info.estimatedClipSize(length: 8, content: .videoAndSound) == whole)
        #expect(info.estimatedClipSize(length: 8, content: .soundOnly) == 128_000)
        #expect(info.estimatedClipSize(length: 8, content: .videoOnly) == whole - 128_000)
        let unknown = MediaInfo(
            url: info.url, kind: .video, duration: 10, fileSize: 1, displaySize: nil, frameRate: 25,
            estimatedBitRate: 1_000_000)
        #expect(unknown.estimatedClipSize(length: 8, content: .soundOnly) == unknown.estimatedClipSize(length: 8))
    }

    @Test func confirmedSoundOnlySaveWritesAudioFile() async throws {
        let model = try await openedMP4()
        model.exportContent = .soundOnly
        model.setHandle(.start, to: 1)
        model.setHandle(.end, to: 2.5)
        model.prepareSave()
        let proposal = try await proposal(of: model)

        model.confirmSave(to: proposal.destination)
        #expect(
            await waitUntil(timeout: .seconds(20)) { model.saveState == .saved(url: proposal.destination, length: 1.5) }
        )
        let tracks = try await AVURLAsset(url: proposal.destination).load(.tracks)
        #expect(tracks.map(\.mediaType) == [.audio])
    }

    private func current(_ model: EditorModel) throws -> SaveProposal {
        guard case .confirming(let proposal) = model.saveState else { throw CancellationError() }
        return proposal
    }
}
