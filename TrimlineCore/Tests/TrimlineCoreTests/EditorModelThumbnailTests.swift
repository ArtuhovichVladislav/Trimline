import Foundation
import Testing

@testable import TrimlineCore

@MainActor
@Suite struct EditorModelThumbnailTests {
    private func openedModel(_ engine: FakeEngine) async throws -> EditorModel {
        let model = EditorModel(clipSuffix: "clip", opener: { _ throws(MediaOpenError) in engine })
        model.open(engine.info.url)
        try #require(await waitUntil { model.phase == .ready })
        return model
    }

    @Test func wholeFileRequestCoversDuration() async throws {
        let model = try await openedModel(FakeEngine.video(duration: 100))
        model.requestThumbnails(count: 4, height: 60)
        #expect(model.thumbnails.range == 0...100)
        #expect(model.thumbnails.images.count == 4)
        #expect(model.thumbnails.slot(1) == 25...50)
        #expect(model.previousThumbnails == nil)
    }

    @Test func keepsFinishedStripUntilNewOneLoads() async throws {
        let model = try await openedModel(FakeEngine.video(duration: 100))
        model.requestThumbnails(count: 4, height: 60, in: 0...100)
        try #require(await waitUntil { model.thumbnails.isFinished })
        model.requestThumbnails(count: 4, height: 60, in: 20...200)
        #expect(model.thumbnails.range == 20...100)
        #expect(!model.thumbnails.isFinished)
        #expect(model.previousThumbnails?.range == 0...100)
        #expect(await waitUntil { model.previousThumbnails == nil })
        #expect(model.thumbnails.isFinished)
    }

    @Test func closingDropsThumbnails() async throws {
        let model = try await openedModel(FakeEngine.video(duration: 100))
        model.requestThumbnails(count: 4, height: 60, in: 0...100)
        model.closeCurrentFile()
        #expect(model.thumbnails.isEmpty)
        #expect(model.previousThumbnails == nil)
    }

    @Test func audioHasNoThumbnails() async throws {
        let model = try await openedModel(FakeEngine.audio())
        model.requestThumbnails(count: 4, height: 60, in: 0...10)
        #expect(model.thumbnails.isEmpty)
    }
}
