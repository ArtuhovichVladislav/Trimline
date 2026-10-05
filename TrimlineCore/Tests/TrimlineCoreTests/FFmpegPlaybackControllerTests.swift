import AVFoundation
import Foundation
import Testing

@testable import TrimlineCore

@MainActor
@Suite(.enabled(if: ExternalFFmpeg.isAvailable)) struct FFmpegPlaybackControllerTests {
    enum Movie: CaseIterable, Sendable {
        case vp9
        case h264

        // ffmpeg runs synchronously; off the main actor it doesn't stall playback in parallel tests.
        nonisolated func make() async throws -> URL {
            switch self {
            case .vp9: try PlaybackFixtures.vp9MKV()
            case .h264: try PlaybackFixtures.h264MKV()
            }
        }
    }

    private static let tolerance: TimeInterval = 0.1

    nonisolated private static func fixture(_ make: @Sendable () throws -> URL) async throws -> URL {
        try make()
    }

    @Test(arguments: Movie.allCases)
    func preciseSeekShowsFrameAndReportsTime(_ movie: Movie) async throws {
        let url = try await movie.make()
        let playback = FFmpegPlaybackController(url: url, info: PlaybackFixtures.info(for: url, kind: .video))
        defer { playback.close() }
        let surface = try #require(playback.surface as? PlaybackSurfaceLayer)
        var reported: [TimeInterval] = []
        playback.onTimeChange = { reported.append($0) }

        playback.seek(to: 2.2, precise: true)
        #expect(playback.currentTime == 2.2)
        #expect(await waitUntil { reported.contains { abs($0 - 2.2) < 0.001 } })
        #expect(abs(playback.currentTime - 2.2) < 0.001)
        #expect(!playback.isPlaying)
        // Without a window nothing is drawn, so this is as far as a test can see.
        #expect(await waitUntil { surface.displayLayer.sampleBufferRenderer.status == .rendering })
    }

    @Test(arguments: Movie.allCases)
    func fastSeekLandsOnKeyframe(_ movie: Movie) async throws {
        let url = try await movie.make()
        let playback = FFmpegPlaybackController(url: url, info: PlaybackFixtures.info(for: url, kind: .video))
        defer { playback.close() }
        var reported: [TimeInterval] = []
        playback.onTimeChange = { reported.append($0) }

        playback.seek(to: 1, precise: true)
        playback.seek(to: 2.6, precise: false)
        #expect(playback.currentTime == 2.6)
        #expect(await waitUntil { reported.contains { abs($0 - 2) < 0.001 } })
        #expect(abs(playback.currentTime - 2) < 0.001)
    }

    @Test func scrubbingSettlesOnLastSeek() async throws {
        let url = try await Movie.vp9.make()
        let playback = FFmpegPlaybackController(url: url, info: PlaybackFixtures.info(for: url, kind: .video))
        defer { playback.close() }
        var reported: [TimeInterval] = []
        playback.onTimeChange = { reported.append($0) }
        for step in 0..<30 {
            playback.seek(to: Double(step) * 0.1, precise: false)
            try await Task.sleep(for: .milliseconds(5))
        }
        playback.seek(to: 3.3, precise: true)

        #expect(await waitUntil { reported.last == 3.3 })
        try await Task.sleep(for: .milliseconds(200))
        #expect(reported.last == 3.3)
        #expect(playback.currentTime == 3.3)
    }

    @Test func turnsRotatedVideo() async throws {
        let url = try await Self.fixture(PlaybackFixtures.rotatedMKV)
        let playback = FFmpegPlaybackController(url: url, info: PlaybackFixtures.info(for: url, kind: .video))
        defer { playback.close() }
        let surface = try #require(playback.surface as? PlaybackSurfaceLayer)
        #expect(await waitUntil { surface.quarterTurns != 0 })
        // ffmpeg's display rotation is counter-clockwise, so 90° there is three clockwise quarter turns.
        #expect(surface.quarterTurns == 3)
        surface.frame = CGRect(x: 0, y: 0, width: 400, height: 300)
        surface.layoutIfNeeded()
        #expect(surface.displayLayer.bounds.size == CGSize(width: 300, height: 400))
        let turnedFrame = surface.displayLayer.frame
        #expect(abs(turnedFrame.width - 400) < 0.001 && abs(turnedFrame.height - 300) < 0.001)
        #expect(abs(turnedFrame.minX) < 0.001 && abs(turnedFrame.minY) < 0.001)
    }

    @Test(.timeLimit(.minutes(1)), arguments: Movie.allCases)
    func stopsAtEndOfRange(_ movie: Movie) async throws {
        let url = try await movie.make()
        let playback = FFmpegPlaybackController(url: url, info: PlaybackFixtures.info(for: url, kind: .video))
        defer { playback.close() }
        var times: [TimeInterval] = []
        playback.onTimeChange = { times.append($0) }
        let started = ContinuousClock.now
        await withCheckedContinuation { (stopped: CheckedContinuation<Void, Never>) in
            playback.onPlaybackStop = { stopped.resume() }
            playback.play(within: 1...2, looping: false)
            #expect(playback.isPlaying)
        }
        let elapsed = ContinuousClock.now - started

        #expect(!playback.isPlaying)
        #expect(abs(playback.currentTime - 2) < Self.tolerance)
        #expect(times.contains { (1.3...1.7).contains($0) })
        // Only the lower bound is tight: the parallel suite can hold up the main actor for a while.
        #expect(elapsed > .milliseconds(900) && elapsed < .seconds(5))
    }

    @Test(.timeLimit(.minutes(1)), arguments: Movie.allCases)
    func loopsBackToRangeStart(_ movie: Movie) async throws {
        let url = try await movie.make()
        let playback = FFmpegPlaybackController(url: url, info: PlaybackFixtures.info(for: url, kind: .video))
        defer { playback.close() }
        var stopped = false
        playback.onPlaybackStop = { stopped = true }
        await withCheckedContinuation { (wrapped: CheckedContinuation<Void, Never>) in
            var latest: TimeInterval = 0
            var resumed = false
            playback.onTimeChange = { time in
                if !resumed, time < latest - 0.2 {
                    resumed = true
                    wrapped.resume()
                }
                latest = time
            }
            playback.play(within: 0.5...1, looping: true)
        }

        #expect(playback.isPlaying)
        #expect(!stopped)
        #expect((0.4...1).contains(playback.currentTime))
        playback.pause()
        #expect(!playback.isPlaying)
    }

    @Test(.timeLimit(.minutes(1)))
    func playsAudioOnlyFile() async throws {
        let url = try await Self.fixture(PlaybackFixtures.oggVorbis)
        let playback = FFmpegPlaybackController(url: url, info: PlaybackFixtures.info(for: url, kind: .audio))
        defer { playback.close() }
        #expect(playback.surface == nil)
        await withCheckedContinuation { (stopped: CheckedContinuation<Void, Never>) in
            playback.onPlaybackStop = { stopped.resume() }
            playback.play(within: 0.5...1.2, looping: false)
        }
        #expect(!playback.isPlaying)
        #expect(abs(playback.currentTime - 1.2) < Self.tolerance)
    }

    @Test func closeIsSafeTwiceAndStopsEverything() async throws {
        let url = try await Movie.h264.make()
        let playback = FFmpegPlaybackController(url: url, info: PlaybackFixtures.info(for: url, kind: .video))
        var reports = 0
        playback.onTimeChange = { _ in reports += 1 }
        playback.play(within: 0...3, looping: false)
        playback.close()
        playback.close()
        playback.seek(to: 1, precise: true)
        playback.play(within: 0...3, looping: false)

        #expect(!playback.isPlaying)
        try await Task.sleep(for: .milliseconds(300))
        #expect(reports == 0)
    }

    @Test func unreadableFileStopsPlayback() async throws {
        let url = try PlaybackFixtures.notMedia()
        let playback = FFmpegPlaybackController(url: url, info: PlaybackFixtures.info(for: url, kind: .video))
        defer { playback.close() }
        var stopped = false
        playback.onPlaybackStop = { stopped = true }
        playback.play(within: 0...1, looping: false)
        #expect(await waitUntil(timeout: .seconds(20)) { stopped })
        #expect(!playback.isPlaying)
    }
}
