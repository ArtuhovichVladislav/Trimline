import Foundation
import Testing

@testable import TrimlineCore

@Suite struct WaveformBuilderTests {
    @Test func buildsPeaksOfSine() async throws {
        let cache = WaveformCache(directory: try TestMedia.makeTemporaryFolder())
        let engine = try await AVFoundationEngine.open(try await TestMedia.audio(), waveformCache: cache)

        let peaks = try await collect(engine.peaks(buckets: 100), buckets: 100)
        #expect(peaks.count == 100)
        // The test tone is a sine at 80% of full scale.
        #expect(peaks.allSatisfy { $0.max > 0.7 && $0.min < -0.7 })
        #expect(peaks.allSatisfy { $0.max <= 1 && $0.min >= -1 })
    }

    @Test func readsSecondBuildFromCache() async throws {
        let folder = try TestMedia.makeTemporaryFolder()
        let cache = WaveformCache(directory: folder)
        let url = try await TestMedia.audio(.init(fileType: .m4a))
        let first = try await collect(
            try await AVFoundationEngine.open(url, waveformCache: cache).peaks(buckets: 50), buckets: 50)

        let entries = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(entries.count == 1)

        var chunks: [PeakChunk] = []
        for await chunk in try await AVFoundationEngine.open(url, waveformCache: cache).peaks(buckets: 50) {
            chunks.append(chunk)
        }
        #expect(chunks.count == 1)
        #expect(chunks.first?.peaks == first)
    }

    @Test func buildsPeaksForMovieSound() async throws {
        let cache = WaveformCache(directory: try TestMedia.makeTemporaryFolder())
        let engine = try await AVFoundationEngine.open(try await TestMedia.video(), waveformCache: cache)
        let peaks = try await collect(engine.peaks(buckets: 40), buckets: 40)
        #expect(peaks.contains { $0.max > 0.5 })
    }

    private func collect(_ stream: AsyncStream<PeakChunk>, buckets: Int) async throws -> [Peak] {
        var peaks: [Peak] = []
        for await chunk in stream {
            try #require(chunk.firstBucket == peaks.count)
            peaks.append(contentsOf: chunk.peaks)
        }
        return peaks
    }
}

@Suite struct PeakAccumulatorTests {
    @Test func padsShortInputToBucketCount() {
        var accumulator = PeakAccumulator(bucketCount: 10, estimatedFrameCount: 100)
        feed(&accumulator, Array(repeating: 0.5, count: 30))
        let chunk = accumulator.finish()
        #expect(accumulator.completed.count == 10)
        #expect(chunk?.firstBucket == 0)
        #expect(accumulator.completed.prefix(3).allSatisfy { $0.max == 0.5 })
        #expect(accumulator.completed.suffix(6).allSatisfy { $0 == Peak(min: 0, max: 0) })
    }

    @Test func foldsExtraInputIntoLastBucket() {
        var accumulator = PeakAccumulator(bucketCount: 4, estimatedFrameCount: 8)
        feed(&accumulator, [0.1, 0.1, 0.2, 0.2, 0.3, 0.3, 0.4, 0.4, 0.9, -0.9])
        _ = accumulator.finish()
        #expect(
            accumulator.completed == [
                Peak(min: 0.1, max: 0.1), Peak(min: 0.2, max: 0.2), Peak(min: 0.3, max: 0.3), Peak(min: -0.9, max: 0.9),
            ])
    }

    @Test func takesMaximumAcrossChannels() {
        var accumulator = PeakAccumulator(bucketCount: 1, estimatedFrameCount: 2)
        feed(&accumulator, [0.2, -0.7, 0.6, 0.1], channels: 2)
        _ = accumulator.finish()
        #expect(accumulator.completed == [Peak(min: -0.7, max: 0.6)])
    }

    @Test func handsOutChunksInOrder() {
        var accumulator = PeakAccumulator(bucketCount: 8, estimatedFrameCount: 8)
        feed(&accumulator, Array(repeating: 1, count: 5))
        let first = accumulator.takeChunk(minimumSize: 2)
        #expect(first?.firstBucket == 0)
        #expect(first?.peaks.count == 5)
        #expect(accumulator.takeChunk(minimumSize: 2) == nil)
        let last = accumulator.finish()
        #expect(last?.firstBucket == 5)
        #expect(last?.peaks.count == 3)
    }

    @Test func handlesMoreBucketsThanFrames() {
        var accumulator = PeakAccumulator(bucketCount: 10, estimatedFrameCount: 3)
        feed(&accumulator, [0.5, 0.5, 0.5])
        _ = accumulator.finish()
        #expect(accumulator.completed.count == 10)
    }

    private func feed(_ accumulator: inout PeakAccumulator, _ samples: [Float], channels: Int = 1) {
        samples.withUnsafeBufferPointer { accumulator.add($0, channels: channels) }
    }
}
