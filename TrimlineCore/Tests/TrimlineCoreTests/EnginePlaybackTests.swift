import Foundation
import Testing

@testable import TrimlineCore

@MainActor
@Suite struct EnginePlaybackTests {
    @Test func videoPlaybackHasSurface() async throws {
        let engine = try await MediaOpener.open(try await TestMedia.video())
        let playback = engine.makePlayback()
        #expect(playback.surface != nil)
        #expect(!playback.isPlaying)
        #expect(playback.currentTime == 0)

        playback.seek(to: 1, precise: false)
        playback.seek(to: 2, precise: true)
        #expect(playback.currentTime == 2)
        playback.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func stopsAtEndOfRange() async throws {
        let engine = try await MediaOpener.open(try await TestMedia.video(.init(withAudio: false)))
        let playback = engine.makePlayback()
        defer { playback.close() }
        var times: [TimeInterval] = []
        playback.onTimeChange = { times.append($0) }
        await withCheckedContinuation { (stopped: CheckedContinuation<Void, Never>) in
            playback.onPlaybackStop = { stopped.resume() }
            playback.play(within: 1...1.5, looping: false)
        }

        #expect(!playback.isPlaying)
        #expect(abs(playback.currentTime - 1.5) < 0.1)
        #expect(times.contains { (1...1.6).contains($0) })
    }

    @Test(.timeLimit(.minutes(1)))
    func loopsBackToRangeStart() async throws {
        let engine = try await MediaOpener.open(try await TestMedia.video(.init(withAudio: false)))
        let playback = engine.makePlayback()
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
            playback.play(within: 0.5...0.9, looping: true)
        }

        #expect(playback.isPlaying)
        #expect(!stopped)
        #expect((0.4...0.9).contains(playback.currentTime))
        playback.pause()
    }

    @Test func audioPlaybackHasNoSurface() async throws {
        let engine = try await MediaOpener.open(try await TestMedia.audio())
        let playback = engine.makePlayback()
        #expect(playback.surface == nil)
        playback.close()
    }
}
