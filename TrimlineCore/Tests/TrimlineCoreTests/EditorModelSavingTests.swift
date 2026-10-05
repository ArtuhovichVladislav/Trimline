import Foundation
import Testing

@testable import TrimlineCore

@MainActor
@Suite struct EditorModelSavingTests {
    private static let suffix = "clip"

    private func openedModel(_ engine: FakeEngine) async throws -> EditorModel {
        let model = EditorModel(clipSuffix: Self.suffix, opener: { _ throws(MediaOpenError) in engine })
        model.open(engine.info.url)
        try #require(await waitUntil { model.phase == .ready })
        return model
    }

    private func proposal(of model: EditorModel) async throws -> SaveProposal {
        try #require(
            await waitUntil {
                if case .confirming = model.saveState { return true }
                return false
            })
        guard case .confirming(let proposal) = model.saveState else { throw CancellationError() }
        return proposal
    }

    // A real file, because saving goes through the real exporter.
    private func openedVideoInFolder() async throws -> (EditorModel, URL) {
        let folder = try TestMedia.makeTemporaryFolder()
        let source = folder.appendingPathComponent("movie.mov")
        try FileManager.default.copyItem(at: try await TestMedia.video(), to: source)
        let engine = FakeEngine.video(url: source, duration: 4, frameRate: 30, keyframes: [0, 1, 2, 3])
        return (try await openedModel(engine), folder)
    }

    @Test func proposalStartsOnKeyframeWithFreeName() async throws {
        let folder = try TestMedia.makeTemporaryFolder()
        let source = folder.appendingPathComponent("movie.mkv")
        try Data().write(to: source)
        try Data().write(to: folder.appendingPathComponent("movie (clip).mkv"))
        let model = try await openedModel(FakeEngine.video(url: source))
        model.exportMode = .precise
        model.setHandle(.start, to: 3.3)
        model.setHandle(.end, to: 7)
        model.exportMode = .fast

        model.prepareSave()
        let proposal = try await proposal(of: model)
        #expect(proposal.destination.lastPathComponent == "movie (clip 2).mkv")
        #expect(proposal.range == 2...7)
        #expect(proposal.folderIsWritable)
    }

    @Test func readOnlyContainerIsSavedAsMatroska() async throws {
        let folder = try TestMedia.makeTemporaryFolder()
        let model = try await openedModel(FakeEngine.video(url: folder.appendingPathComponent("movie.rmvb")))
        model.prepareSave()
        let proposal = try await proposal(of: model)
        #expect(proposal.destination.lastPathComponent == "movie (clip).mkv")
        #expect(proposal.changesContainer)
    }

    @Test func writableContainerIsKept() async throws {
        let folder = try TestMedia.makeTemporaryFolder()
        let model = try await openedModel(FakeEngine.video(url: folder.appendingPathComponent("movie.webm")))
        model.prepareSave()
        let proposal = try await proposal(of: model)
        #expect(proposal.destination.pathExtension == "webm")
        #expect(!proposal.changesContainer)
    }

    @Test func preciseProposalKeepsExactStart() async throws {
        let folder = try TestMedia.makeTemporaryFolder()
        let model = try await openedModel(FakeEngine.video(url: folder.appendingPathComponent("movie.mov")))
        model.exportMode = .precise
        model.setHandle(.start, to: 3.3)
        model.prepareSave()
        #expect(try await proposal(of: model).range.lowerBound == 3.3)
    }

    // Every native container keeps exact starts, so a changed name template shows the recomputation.
    @Test func changingModeRecomputesProposal() async throws {
        let folder = try TestMedia.makeTemporaryFolder()
        let model = try await openedModel(FakeEngine.video(url: folder.appendingPathComponent("movie.mp4")))
        model.exportMode = .precise
        model.setHandle(.start, to: 3.3)
        model.prepareSave()
        #expect(try await proposal(of: model).range.lowerBound == 3.3)

        model.naming = FileNaming(template: try FileNameTemplate("{name} fast"))
        model.exportMode = .fast
        let renamed = await waitUntil {
            (try? self.currentProposal(model).destination.lastPathComponent) == "movie fast.mp4"
        }
        #expect(renamed)
        #expect(try currentProposal(model).range.lowerBound == 3.3)
    }

    @Test func staleProposalCannotBeSaved() async throws {
        let folder = try TestMedia.makeTemporaryFolder()
        let model = try await openedModel(FakeEngine.video(url: folder.appendingPathComponent("movie.mkv")))
        model.exportMode = .precise
        model.setHandle(.start, to: 3.3)
        model.prepareSave()
        let precise = try await proposal(of: model)
        #expect(model.isSaveProposalCurrent)

        model.exportMode = .fast
        #expect(!model.isSaveProposalCurrent)
        model.confirmSave(to: precise.destination)
        #expect(model.saveState == .confirming(precise))
        #expect(await waitUntil { (try? self.currentProposal(model).mode) == .fast })
        #expect(try currentProposal(model).range.lowerBound == 2)
        #expect(model.isSaveProposalCurrent)
    }

    @Test func openingAFileKeepsTheMode() async throws {
        let engine = FakeEngine.video()
        let model = EditorModel(clipSuffix: Self.suffix, opener: { _ throws(MediaOpenError) in engine })
        model.exportMode = .precise
        model.open(engine.info.url)
        #expect(model.exportMode == .precise)
    }

    @Test func proposalUsesNameTemplate() async throws {
        let folder = try TestMedia.makeTemporaryFolder()
        let model = try await openedModel(FakeEngine.audio(url: folder.appendingPathComponent("song.m4a")))
        model.naming = FileNaming(template: try FileNameTemplate("{name} – excerpt"))
        model.prepareSave()
        #expect(try await proposal(of: model).destination.lastPathComponent == "song – excerpt.m4a")
    }

    @Test func askingForDestinationIsReported() async throws {
        let folder = try TestMedia.makeTemporaryFolder()
        let model = try await openedModel(FakeEngine.audio(url: folder.appendingPathComponent("song.m4a")))
        model.prepareSave()
        #expect(try await !proposal(of: model).asksForDestination)
        model.cancelSave()

        model.alwaysAsksForDestination = true
        model.prepareSave()
        let proposal = try await proposal(of: model)
        #expect(proposal.asksForDestination)
        #expect(proposal.folderIsWritable)
    }

    private func currentProposal(_ model: EditorModel) throws -> SaveProposal {
        guard case .confirming(let proposal) = model.saveState else { throw CancellationError() }
        return proposal
    }

    @Test func confirmedSaveWritesClip() async throws {
        let (model, _) = try await openedVideoInFolder()
        model.setHandle(.start, to: 1)
        model.setHandle(.end, to: 2.5)
        model.prepareSave()
        let proposal = try await proposal(of: model)

        model.confirmSave(to: proposal.destination)
        #expect(
            await waitUntil(timeout: .seconds(20)) { model.saveState == .saved(url: proposal.destination, length: 1.5) }
        )
        #expect(FileManager.default.fileExists(atPath: proposal.destination.path))
    }

    @Test func cancellingProposalReturnsToIdle() async throws {
        let (model, _) = try await openedVideoInFolder()
        model.prepareSave()
        _ = try await proposal(of: model)
        model.cancelSave()
        #expect(model.saveState == .idle)
    }

    @Test func cancellingSaveLeavesNoClip() async throws {
        let (model, _) = try await openedVideoInFolder()
        model.prepareSave()
        let proposal = try await proposal(of: model)
        model.confirmSave(to: proposal.destination)
        model.cancelSave()
        #expect(model.saveState == .idle)

        try await Task.sleep(for: .milliseconds(500))
        #expect(model.saveState == .idle)
        #expect(!FileManager.default.fileExists(atPath: proposal.destination.path))
    }

    @Test func failedSaveIsReported() async throws {
        let (model, folder) = try await openedVideoInFolder()
        model.prepareSave()
        let proposal = try await proposal(of: model)
        try Data().write(to: proposal.destination)

        model.confirmSave(to: proposal.destination)
        #expect(await waitUntil { model.saveState == .failed(.destinationExists) })
        #expect(try Data(contentsOf: folder.appendingPathComponent(proposal.destination.lastPathComponent)).isEmpty)
    }
}
