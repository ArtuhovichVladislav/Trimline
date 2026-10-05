import Foundation
import Testing

@testable import TrimlineCore

// Files whose streams don't start together: the picture a second after the sound, or the other way round.
@MainActor
@Suite(.enabled(if: ExternalFFmpeg.isAvailable)) struct StreamOffsetPlaybackTests {
    enum Offset: CaseIterable, Sendable {
        case lateVideo
        case lateAudio

        // ffmpeg runs synchronously; off the main actor it doesn't stall playback in parallel tests.
        nonisolated func make() async throws -> URL {
            switch self {
            case .lateVideo: try FFmpegFixtures.lateVideoMKV()
            case .lateAudio: try FFmpegFixtures.lateAudioMKV()
            }
        }
    }

    // A stream with nothing near the clock used to hold every seek, and with it the clock, forever.
    @Test(.timeLimit(.minutes(1)), arguments: Offset.allCases)
    func playsThroughTheStretchWithOneStream(_ offset: Offset) async throws {
        let url = try await offset.make()
        let playback = FFmpegPlaybackController(url: url, info: PlaybackFixtures.info(for: url, kind: .video))
        defer { playback.close() }
        var reported: [TimeInterval] = []
        var stopped = false
        playback.onTimeChange = { reported.append($0) }
        playback.onPlaybackStop = { stopped = true }

        #expect(await waitUntil { reported.contains(0) })
        playback.play(within: 0...1.5, looping: false)
        #expect(await waitUntil(timeout: .seconds(10)) { stopped })
        #expect(reported.contains { (0.3...1.2).contains($0) })
        #expect(abs(playback.currentTime - 1.5) < 0.1)

        playback.seek(to: 2.5, precise: true)
        #expect(await waitUntil { reported.last == 2.5 })
        playback.seek(to: 0.2, precise: true)
        #expect(await waitUntil { reported.last == 0.2 })
    }

    @Test func controllerDroppedWithoutClosingGoesAway() async throws {
        let url = try await Self.fixture(PlaybackFixtures.h264MKV)
        weak var dropped: FFmpegPlaybackController?
        do {
            let playback = FFmpegPlaybackController(url: url, info: PlaybackFixtures.info(for: url, kind: .video))
            dropped = playback
            var settled = false
            playback.onTimeChange = { _ in settled = true }
            // Paused after the opening seek, the feeders wait for the clock to start.
            #expect(await waitUntil { settled })
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(await waitUntil { dropped == nil })
    }

    nonisolated private static func fixture(_ make: @Sendable () throws -> URL) async throws -> URL {
        try make()
    }
}

@Suite(.enabled(if: ExternalFFmpeg.isAvailable)) struct StreamOffsetPipelineTests {
    // A seek on the picture lands on its first key frame, a second after the sound has started.
    @Test(arguments: [0, 0.4])
    func soundBeforeThePictureIsPlayed(_ target: TimeInterval) async throws {
        let pipeline = PlaybackPipeline(url: try FFmpegFixtures.lateVideoMKV(), includesVideo: true)
        #expect(await pipeline.open()?.tracks == [.video, .audio])
        let seek = await pipeline.seek(to: target, precise: true)

        let sound = try #require(await pipeline.nextSample(for: .audio, generation: seek.generation))
        #expect(abs(sound.presentationTime - target) < 0.001)
        let picture = try #require(await pipeline.nextSample(for: .video, generation: seek.generation))
        #expect(abs(picture.presentationTime - 1) < 0.001)
    }
}

@Suite(.enabled(if: ExternalFFmpeg.isAvailable)) struct StreamOffsetExportTests {
    // AAC frames are 23 ms at 44.1 kHz; the clip's ends are rounded to them.
    private static let audioTolerance: TimeInterval = 0.06

    @Test(arguments: [ExportMode.fast, .precise])
    func soundBeforeThePictureIsKept(_ mode: ExportMode) throws {
        let source = try FFmpegFixtures.lateVideoMKV()
        let clip = try Self.export(source, range: 0.5...3.5, mode: mode)

        #expect(abs(try FFprobe.report(clip).format.seconds - 3) < Self.audioTolerance)
        let sound = try #require(try FFprobe.firstPacketTimes(clip, stream: "a:0").first)
        #expect(abs(sound) < Self.audioTolerance)
        let picture = try #require(try FFprobe.firstPacketTimes(clip, stream: "v:0").first)
        #expect(abs(picture - 0.5) < 0.01)
    }

    // The save panel shows the start fast saving snaps to; the written clip must start there too.
    @Test(arguments: [0.5, 2.3])
    func savePanelStartIsWhereTheClipStarts(_ requested: TimeInterval) async throws {
        let source = try FFmpegFixtures.lateVideoMKV()
        let engine = try await FFmpegEngine.open(source)
        let start = await engine.keyframe(atOrBefore: requested)
        #expect(start == (requested < 1 ? requested : 2))

        let clip = try Self.export(source, range: start...3.5, mode: .fast)
        #expect(abs(try FFprobe.report(clip).format.seconds - (3.5 - start)) < Self.audioTolerance)
    }

    // An interrupted download: no cues, no duration, the end cut off mid-cluster. The selection runs past
    // what is left; the clip may stop early or the save may fail, but only with an error the sheet can show.
    @Test(arguments: [ExportMode.fast, .precise])
    func truncatedFileSavesOrFailsCleanly(_ mode: ExportMode) throws {
        let source = try FFmpegFixtures.truncatedMKV()
        let container = ExportContainer.forSource(source, mode: mode)
        let clip = try TestMedia.makeTemporaryFolder().appendingPathComponent("clip.\(container.fileExtension)")
        do throws(RemuxError) {
            _ = try Transcoder(source: source, container: container, mode: mode)
                .export(1...3.9, to: clip, isCancelled: { false }, progress: { _ in })
        } catch {
            return
        }
        let report = try FFprobe.report(clip)
        #expect(report.format.seconds > 0.5)
        #expect(report.streams.map(\.codecType) == ["video", "audio"])
    }

    private static func export(_ source: URL, range: ClosedRange<TimeInterval>, mode: ExportMode) throws -> URL {
        let container = ExportContainer.forSource(source, mode: mode)
        let clip = try TestMedia.makeTemporaryFolder().appendingPathComponent("clip.\(container.fileExtension)")
        _ = try Transcoder(source: source, container: container, mode: mode)
            .export(range, to: clip, isCancelled: { false }, progress: { _ in })
        return clip
    }
}
