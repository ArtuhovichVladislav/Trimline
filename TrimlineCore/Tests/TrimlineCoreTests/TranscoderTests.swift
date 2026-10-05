import AVFoundation
import Foundation
import Testing

@testable import TrimlineCore

@Suite(.serialized, .enabled(if: ExternalFFmpeg.isAvailable)) struct TranscoderTests {
    typealias Source = TranscodeFixtures.Source

    // Starts on frame 13, between the key frames at 0 and 1 s.
    private static let range: ClosedRange<TimeInterval> = 0.52...1.6
    private static let selection = range.upperBound - range.lowerBound
    private static let frame = 1 / TranscodeFixtures.frameRate
    // The last copied audio packet may reach a little past the end.
    private static let lengthTolerance = frame + 0.005
    private static let colorTolerance = TranscodeFixtures.redPerFrame / 2
    private static let sampleTolerance = 0.001

    // MARK: Precise mode

    @Test(arguments: [
        (Source.matroskaH264, "h264", false), (.matroskaVP9, "hevc", false), (.webmVP9, "hevc", true),
        (.aviMPEG4, "hevc", true),
    ])
    func preciseStartsOnTheRequestedFrame(_ fixture: Source, codec: String, changesContainer: Bool) async throws {
        let source = try TranscodeFixtures.make(fixture)
        let (clip, container) = try await export(source, range: Self.range, mode: .precise)
        #expect(container.changesContainer == changesContainer)
        #expect(clip.pathExtension == (changesContainer ? "mkv" : fixture.fileExtension))

        let report = try FFprobe.report(clip)
        #expect(report.streams.filter { $0.codecType == "video" }.map(\.codecName) == [codec])
        #expect(report.streams.count { $0.codecType == "audio" } == fixture.audioTracks)
        #expect(abs(report.format.seconds - Self.selection) <= Self.lengthTolerance)
        if changesContainer {
            #expect(report.format.formatName.hasPrefix("matroska"))
        }
        try expectFirstFrame(of: clip, matches: source)
    }

    @Test func tenBitHEVCStaysTenBit() async throws {
        let source = try TranscodeFixtures.make(.matroskaHEVC10)
        let (clip, container) = try await export(source, range: Self.range, mode: .precise)
        #expect(!container.changesContainer)
        let video = try #require(try FFprobe.report(clip).streams.first { $0.codecType == "video" })
        #expect(video.codecName == "hevc")
        #expect(video.profile == "Main 10")
        #expect(video.pixFmt == "yuv420p10le")
        try expectFirstFrame(of: clip, matches: source)
    }

    @Test func mp4KeepsH264AndSizeThroughTranscoder() async throws {
        let source = try TranscodeFixtures.make(.mp4H264)
        let clip = try transcode(source, container: ExportContainer.forSource(source), mode: .precise)
        let report = try FFprobe.report(clip)
        let video = try #require(report.streams.first { $0.codecType == "video" })
        #expect(video.codecName == "h264")
        #expect(video.width == 320 && video.height == 180)
        #expect(abs(report.format.seconds - Self.selection) <= Self.lengthTolerance)
        try expectFirstFrame(of: clip, matches: source)
    }

    @Test func hevcEncodedIntoMP4OpensInAVFoundation() async throws {
        let source = try ExternalFFmpeg.testMovie(
            "transcode-vp9.mp4", codec: ["-c:v", "libvpx-vp9", "-deadline", "realtime", "-c:a", "aac"])
        let clip = try transcode(source, container: ExportContainer.forSource(source), mode: .precise)
        let video = try #require(try FFprobe.report(clip).streams.first { $0.codecType == "video" })
        #expect(video.codecName == "hevc")
        #expect(video.codecTagString == "hvc1")

        let asset = AVURLAsset(url: clip)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        #expect(try await track.load(.isDecodable))
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output)
        #expect(reader.startReading())
        #expect(output.copyNextSampleBuffer()?.imageBuffer != nil)
    }

    @Test func rotationSurvivesReencoding() async throws {
        let source = try RemuxFixtures.rotatedMovie()
        let clip = try transcode(source, container: ExportContainer.forSource(source), mode: .precise)
        let rotation = try FFprobe.report(source).streams.first?.rotation
        #expect(rotation != nil)
        #expect(try FFprobe.report(clip).streams.first?.rotation == rotation)
    }

    @Test func progressMovesForwardToCompletion() async throws {
        let source = try TranscodeFixtures.make(.matroskaVP9)
        let folder = try TestMedia.makeTemporaryFolder()
        let request = ExportRequest(
            source: source, range: Self.range, mode: .precise,
            destination: folder.appendingPathComponent("clip.mkv"), estimatedSize: 1_000_000)
        var values: [Double] = []
        for try await value in Exporter().export(request) {
            values.append(value)
        }
        #expect(values.count > 2)
        #expect(values.last == 1)
        #expect(values == values.sorted())
    }

    // MARK: Containers that can't hold a copy

    // FFmpeg's RealMedia writer stamps every audio packet with 0, so only a clip from the start has
    // trustworthy sound; RealVideo has no Matroska copy at all.
    @Test func realMediaBecomesHEVCAndAACInMatroska() async throws {
        let source = try RemuxFixtures.realMedia(withVideo: true)
        let (clip, container) = try await export(source, range: 0...2, mode: .fast)
        #expect(container.changesContainer)
        #expect(clip.pathExtension == "mkv")
        let report = try FFprobe.report(clip)
        #expect(report.streams.map(\.codecName) == ["hevc", "aac"])
        // Matroska counts the AAC encoder's priming into the clip's length, so the picture is measured instead.
        #expect(report.streams.first?.matroskaDuration.map { abs($0 - 2) <= Self.frame / 2 } == true)
    }

    @Test func realAudioBecomesAAC() async throws {
        let source = try RemuxFixtures.realMedia(withVideo: false)
        let (clip, _) = try await export(source, range: 0...2, mode: .fast)
        #expect(try FFprobe.report(clip).streams.map(\.codecName) == ["aac"])
    }

    // FFmpeg has no Monkey's Audio encoder for a fixture; WavPack into MP4, which has no WavPack, takes
    // the same lossless path.
    @Test func losslessSoundTheContainerRefusesBecomesFLAC() async throws {
        let source = try RemuxFixtures.make(.wavpack)
        let container = ExportContainer(fileExtension: "mp4", changesContainer: true, muxer: "mp4")
        let clip = try transcode(source, container: container, mode: .fast, range: 1.2...3)
        let report = try FFprobe.report(clip)
        #expect(report.streams.map(\.codecName) == ["flac"])
        #expect(abs(report.format.seconds - 1.8) < Self.sampleTolerance)
    }

    @Test func lossySoundTheContainerRefusesBecomesAAC() async throws {
        let source = try RemuxFixtures.make(.wma)
        let container = ExportContainer(fileExtension: "mp4", changesContainer: true, muxer: "mp4")
        let clip = try transcode(source, container: container, mode: .fast, range: 1.2...3)
        let report = try FFprobe.report(clip)
        #expect(report.streams.map(\.codecName) == ["aac"])
        #expect(abs(report.format.seconds - 1.8) < 0.05)
    }

    // MARK: Container choice

    @Test(arguments: [
        (Source.webmVP9, ExportMode.precise, "mkv"), (.webmVP9, .fast, "webm"), (.matroskaVP9, .precise, "mkv"),
        (.aviMPEG4, .precise, "mkv"), (.aviMPEG4, .fast, "avi"), (.mp4H264, .precise, "mp4"),
    ])
    func containerDependsOnTheEncodedCodec(_ fixture: Source, mode: ExportMode, expected: String) throws {
        let source = try TranscodeFixtures.make(fixture)
        let container = ExportContainer.forSource(source, mode: mode)
        #expect(container.fileExtension == expected)
        #expect(container.changesContainer == (expected != fixture.fileExtension))
    }

    // MARK: Helpers

    private func export(_ source: URL, range: ClosedRange<TimeInterval>, mode: ExportMode) async throws -> (
        URL, ExportContainer
    ) {
        let container = ExportContainer.forSource(source, mode: mode)
        let checksum = try ExporterTests.checksum(of: source)
        let folder = try TestMedia.makeTemporaryFolder()
        let destination = folder.appendingPathComponent("clip.\(container.fileExtension)")
        let request = ExportRequest(
            source: source, range: range, mode: mode, destination: destination, estimatedSize: 1_000_000)
        try await drain(request)
        #expect(try ExporterTests.checksum(of: source) == checksum)
        #expect(try ExporterTests.leftovers(in: folder) == [destination.lastPathComponent])
        return (destination, container)
    }

    private func transcode(
        _ source: URL, container: ExportContainer, mode: ExportMode, range: ClosedRange<TimeInterval> = Self.range
    ) throws -> URL {
        let output = try TestMedia.makeTemporaryFolder().appendingPathComponent("clip.\(container.fileExtension)")
        _ = try Transcoder(source: source, container: container, mode: mode)
            .export(range, to: output, isCancelled: { false }, progress: { _ in })
        return output
    }

    /// The clip opens on the source's frame at the start, not on the key frame or a neighbour.
    private func expectFirstFrame(of clip: URL, matches source: URL) throws {
        let start = Self.range.lowerBound
        let expected = try TranscodeFixtures.averageRed(of: source, at: start)
        let shown = try TranscodeFixtures.averageRed(of: clip, at: 0)
        #expect(abs(shown - expected) < Self.colorTolerance)
        for neighbour in [start - Self.frame, start + Self.frame] {
            #expect(abs(shown - (try TranscodeFixtures.averageRed(of: source, at: neighbour))) > Self.colorTolerance)
        }
    }
}

extension FFprobe.Stream {
    /// Matroska keeps each track's length in a DURATION tag, as hours:minutes:seconds.
    var matroskaDuration: TimeInterval? {
        guard let parts = tags?["DURATION"]?.split(separator: ":").compactMap({ Double($0) }), parts.count == 3
        else { return nil }
        return parts[0] * 3600 + parts[1] * 60 + parts[2]
    }
}
