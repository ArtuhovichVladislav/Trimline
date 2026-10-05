import Foundation
import Testing

@testable import TrimlineCore

@Suite struct ThumbnailGeneratorTests {
    @Test func yieldsRequestedThumbnailsInOrder() async throws {
        let engine = try await MediaOpener.open(try await TestMedia.video())
        var thumbnails: [Thumbnail] = []
        for await thumbnail in engine.thumbnails(count: 6, height: 60, in: 0...engine.info.duration) {
            thumbnails.append(thumbnail)
        }

        #expect(thumbnails.map(\.index) == Array(0..<6))
        #expect(thumbnails.allSatisfy { $0.image.height <= 60 && $0.image.height > 0 })
        #expect(thumbnails.allSatisfy { (0...engine.info.duration).contains($0.time) })
    }

    @Test func stopsWhenConsumerLeaves() async throws {
        let engine = try await MediaOpener.open(try await TestMedia.video())
        var received = 0
        for await _ in engine.thumbnails(count: 50, height: 60, in: 0...engine.info.duration) {
            received += 1
            break
        }
        #expect(received == 1)
    }

    @Test func spreadsRequestTimesAcrossSlots() {
        let times = ThumbnailGenerator.requestTimes(count: 4, in: 0...8)
        #expect(times == [1, 3, 5, 7])
        #expect(ThumbnailGenerator.requestTimes(count: 0, in: 0...8).isEmpty)
    }
}
