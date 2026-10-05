import Foundation
import Testing

@testable import TrimlineCore

@MainActor
@Suite(.enabled(if: ExternalFFmpeg.isAvailable)) struct EditorModelPreciseSavingTests {
    // HEVC has no place in WebM, so a precisely saved WebM clip becomes Matroska; a fast one stays WebM.
    @Test(arguments: [(ExportMode.precise, "mkv"), (.fast, "webm")])
    func proposalContainerFollowsTheMode(_ mode: ExportMode, expected: String) async throws {
        let folder = try TestMedia.makeTemporaryFolder()
        let source = folder.appendingPathComponent("movie.webm")
        try FileManager.default.copyItem(at: try TranscodeFixtures.make(.webmVP9), to: source)
        let engine = FakeEngine.video(url: source, duration: 2, keyframes: [0, 1])
        let model = EditorModel(clipSuffix: "clip", opener: { _ throws(MediaOpenError) in engine })
        model.open(source)
        try #require(await waitUntil { model.phase == .ready })
        model.exportMode = mode
        model.setHandle(.start, to: 0.52)

        model.prepareSave()
        try #require(
            await waitUntil {
                if case .confirming = model.saveState { return true }
                return false
            })
        guard case .confirming(let proposal) = model.saveState else { return }
        #expect(proposal.destination.pathExtension == expected)
        #expect(proposal.changesContainer == (mode == .precise))
        #expect(proposal.range.lowerBound == (mode == .precise ? 0.52 : 0))
    }
}
