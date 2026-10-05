import Foundation
import Testing

@testable import TrimlineCore

@Suite(.enabled(if: ExternalFFmpeg.isAvailable)) struct FFmpegEngineKeyframeTests {
    static let exactKeyframes: [(requested: TimeInterval, expected: TimeInterval)] = [
        (2.5, 2.0), (2.0, 2.0), (1.99, 1.0), (0.4, 0.0), (3.9, 3.0),
    ]

    @Test(arguments: exactKeyframes)
    func findsPreviousKeyframeInMatroska(requested: TimeInterval, expected: TimeInterval) async throws {
        let engine = try await FFmpegEngine.open(try FFmpegFixtures.h264MKV.make())
        #expect(abs(await engine.keyframe(atOrBefore: requested) - expected) < 0.001)
    }

    @Test(arguments: exactKeyframes)
    func findsPreviousKeyframeWithoutCues(requested: TimeInterval, expected: TimeInterval) async throws {
        let engine = try await FFmpegEngine.open(try FFmpegFixtures.matroskaWithoutCues())
        #expect(abs(await engine.keyframe(atOrBefore: requested) - expected) < 0.001)
    }

    @Test(arguments: exactKeyframes)
    func findsPreviousKeyframeInWebM(requested: TimeInterval, expected: TimeInterval) async throws {
        let engine = try await FFmpegEngine.open(try FFmpegFixtures.vp8WebM.make())
        #expect(abs(await engine.keyframe(atOrBefore: requested) - expected) < 0.001)
    }

    // These containers shift the first frame a little (encoder delay, preroll), so key frames sit
    // a fraction of a second after whole seconds.
    @Test(arguments: [FFmpegFixtures.mpegTS, FFmpegFixtures.mpeg4AVI, FFmpegFixtures.wmv, FFmpegFixtures.flv])
    func findsKeyframeNearSecondBoundary(_ movie: FFmpegFixtures.Movie) async throws {
        let engine = try await FFmpegEngine.open(try movie.make())
        let keyframe = await engine.keyframe(atOrBefore: 2.5)
        #expect(keyframe <= 2.5)
        #expect(keyframe > 1.5)
        #expect(await engine.keyframe(atOrBefore: keyframe) == keyframe)
    }

    @Test func returnsAudioTimeUnchanged() async throws {
        let engine = try await FFmpegEngine.open(try FFmpegFixtures.oggVorbis.make())
        #expect(await engine.keyframe(atOrBefore: 1.234) == 1.234)
    }
}

@Suite(.enabled(if: ExternalFFmpeg.isAvailable)) struct FFmpegEngineThumbnailTests {
    @Test(arguments: [FFmpegFixtures.h264MKV, FFmpegFixtures.vp9MKV, FFmpegFixtures.mpeg4AVI, FFmpegFixtures.mpegTS])
    func yieldsRequestedThumbnailsInOrder(_ movie: FFmpegFixtures.Movie) async throws {
        let engine = try await FFmpegEngine.open(try movie.make())
        let thumbnails = await collect(engine.thumbnails(count: 6, height: 60, in: 0...engine.info.duration))

        #expect(thumbnails.map(\.index) == Array(0..<6))
        #expect(thumbnails.allSatisfy { $0.image.height == 60 && abs($0.image.width - 107) <= 1 })
        #expect(thumbnails.allSatisfy { (0...engine.info.duration).contains($0.time) })
        #expect(thumbnails.map(\.time) == thumbnails.map(\.time).sorted())
    }

    @Test(.enabled(if: FFmpegFixtures.hasEncoder("libsvtav1")))
    func decodesAV1Thumbnails() async throws {
        let engine = try await FFmpegEngine.open(try FFmpegFixtures.av1WebM.make())
        let thumbnails = await collect(engine.thumbnails(count: 3, height: 60, in: 0...engine.info.duration))
        #expect(thumbnails.map(\.index) == [0, 1, 2])
    }

    @Test func turnsThumbnailsOfRotatedVideo() async throws {
        let engine = try await FFmpegEngine.open(try FFmpegFixtures.rotatedMKV())
        let thumbnails = await collect(engine.thumbnails(count: 2, height: 64, in: 0...engine.info.duration))
        #expect(thumbnails.count == 2)
        #expect(thumbnails.allSatisfy { $0.image.height == 64 && $0.image.width == 36 })
    }

    @Test func neverUpscales() async throws {
        let engine = try await FFmpegEngine.open(try FFmpegFixtures.h264MKV.make())
        let thumbnails = await collect(engine.thumbnails(count: 1, height: 1_000, in: 0...engine.info.duration))
        #expect(thumbnails.first?.image.height == 180)
    }

    @Test func stopsWhenConsumerLeaves() async throws {
        let engine = try await FFmpegEngine.open(try FFmpegFixtures.h264MKV.make())
        var received = 0
        for await _ in engine.thumbnails(count: 50, height: 60, in: 0...engine.info.duration) {
            received += 1
            break
        }
        #expect(received == 1)
    }

    @Test func audioHasNoThumbnails() async throws {
        let engine = try await FFmpegEngine.open(try FFmpegFixtures.opus.make())
        #expect(await collect(engine.thumbnails(count: 4, height: 60, in: 0...engine.info.duration)).isEmpty)
    }

    private func collect(_ stream: AsyncStream<Thumbnail>) async -> [Thumbnail] {
        var thumbnails: [Thumbnail] = []
        for await thumbnail in stream { thumbnails.append(thumbnail) }
        return thumbnails
    }
}

@Suite(.enabled(if: ExternalFFmpeg.isAvailable)) struct FFmpegEngineWaveformTests {
    @Test(arguments: FFmpegFixtures.audioFiles)
    func buildsPeaksOfSine(_ audio: FFmpegFixtures.AudioFile) async throws {
        try await expectSinePeaks(in: audio.make())
    }

    @Test func buildsPeaksForMovieSound() async throws {
        try await expectSinePeaks(in: FFmpegFixtures.h264MKV.make())
    }

    @Test func readsSecondBuildFromCache() async throws {
        let folder = try TestMedia.makeTemporaryFolder()
        let cache = WaveformCache(directory: folder)
        let url = try FFmpegFixtures.oggVorbis.make()
        let first = try await collect(try await FFmpegEngine.open(url, waveformCache: cache).peaks(buckets: 50))
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).count == 1)

        var chunks: [PeakChunk] = []
        for await chunk in try await FFmpegEngine.open(url, waveformCache: cache).peaks(buckets: 50) {
            chunks.append(chunk)
        }
        #expect(chunks.count == 1)
        #expect(chunks.first?.peaks == first)
    }

    @Test func streamsPeaksInSeveralChunks() async throws {
        let cache = WaveformCache(directory: try TestMedia.makeTemporaryFolder())
        let engine = try await FFmpegEngine.open(try FFmpegFixtures.opus.make(), waveformCache: cache)
        var chunks = 0
        for await _ in engine.peaks(buckets: 1_000) { chunks += 1 }
        #expect(chunks > 1)
    }

    private func expectSinePeaks(in url: URL) async throws {
        let cache = WaveformCache(directory: try TestMedia.makeTemporaryFolder())
        let engine = try await FFmpegEngine.open(url, waveformCache: cache)
        let peaks = try await collect(engine.peaks(buckets: 100))
        #expect(peaks.count == 100)
        // lavfi's sine has amplitude 1/8 (lossy codecs shave some off); codec delay and padding
        // may leave the very ends quiet.
        #expect(peaks.filter { $0.max > 0.05 && $0.min < -0.05 }.count >= 95)
        #expect(peaks.allSatisfy { $0.max <= 1 && $0.min >= -1 })
    }

    private func collect(_ stream: AsyncStream<PeakChunk>) async throws -> [Peak] {
        var peaks: [Peak] = []
        for await chunk in stream {
            try #require(chunk.firstBucket == peaks.count)
            peaks.append(contentsOf: chunk.peaks)
        }
        return peaks
    }
}
