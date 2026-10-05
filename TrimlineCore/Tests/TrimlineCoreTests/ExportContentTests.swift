import AVFoundation
import Foundation
import Testing

@testable import TrimlineCore

@Suite(.serialized) struct ExportContentTests {
    private static let range: ClosedRange<TimeInterval> = 0.5...1.5
    private static let selection = range.upperBound - range.lowerBound
    private static let audioTolerance: TimeInterval = 0.1
    private static let editListTolerance: TimeInterval = 0.03
    private static let mp4Video = TestMedia.VideoSpec(duration: 4, frameRate: 30, keyframeInterval: 30, fileType: .mp4)

    // MARK: Sources AVFoundation writes

    @Test func fastVideoOnlyCopiesThePictureWithoutSound() async throws {
        let source = try await TestMedia.video(Self.mp4Video)
        let clip = try await export(source, content: .videoOnly)
        #expect(clip.pathExtension == "mp4")
        let tracks = try await AVURLAsset(url: clip).load(.tracks)
        #expect(tracks.map(\.mediaType) == [.video])
        let format = try #require(try await tracks.first?.load(.formatDescriptions).first)
        #expect(format.mediaSubType == .h264)
        #expect(format.dimensions.width == 320)
    }

    @Test func soundOnlyFromMP4IsAnM4A() async throws {
        let source = try await TestMedia.video(Self.mp4Video)
        let clip = try await export(source, content: .soundOnly)
        #expect(clip.pathExtension == "m4a")
        let asset = AVURLAsset(url: clip)
        let tracks = try await asset.load(.tracks)
        #expect(tracks.map(\.mediaType) == [.audio])
        let format = try #require(try await tracks.first?.load(.formatDescriptions).first)
        #expect(format.mediaSubType == .mpeg4AAC)
        #expect(abs(try await asset.load(.duration).seconds - Self.selection) < Self.editListTolerance)
    }

    // QuickTime-family files keep the session's precise path, which keeps HDR and Dolby Vision, unless the
    // picture can be cut smartly (decision 0009); with no key frame inside the range it can't.
    @Test(arguments: [(30, false), (120, true)])
    func preciseVideoOnlyGoesThroughSmartCutOrTheSession(keyframeInterval: Int, usesSession: Bool) async throws {
        let source = try await TestMedia.video(
            .init(duration: 4, frameRate: 30, keyframeInterval: keyframeInterval))
        let request = try makeRequest(source, content: .videoOnly, mode: .precise)
        let container = ExportContainer.forSource(source, mode: .precise, content: .videoOnly)
        #expect(await Exporter().usesAssetExport(request, container: container) == usesSession)
        try await drain(request)
        let asset = AVURLAsset(url: request.destination)
        #expect(try await asset.load(.tracks).map(\.mediaType) == [.video])
        #expect(abs(try await asset.load(.duration).seconds - Self.selection) < 0.1)
    }

    @Test func soundOnlyNeverGoesThroughTheSession() async throws {
        let source = try await TestMedia.video(Self.mp4Video)
        let request = try makeRequest(source, content: .soundOnly, mode: .precise)
        let container = ExportContainer.forSource(source, mode: .precise, content: .soundOnly)
        #expect(!(await Exporter().usesAssetExport(request, container: container)))
    }

    // MARK: Sources only FFmpeg writes

    @Test(.enabled(if: ExternalFFmpeg.isAvailable)) func preciseVideoOnlyGoesThroughTranscoder() async throws {
        let source = try TranscodeFixtures.make(.matroskaH264)
        let request = try makeRequest(source, content: .videoOnly, mode: .precise)
        try await drain(request)
        let report = try FFprobe.report(request.destination)
        #expect(report.streams.map(\.codecType) == ["video"])
        #expect(report.streams.first?.codecName == "h264")
        #expect(abs(report.format.seconds - Self.selection) < Self.audioTolerance)
    }

    @Test(.enabled(if: ExternalFFmpeg.isAvailable)) func videoOnlyKeepsSubtitlesAndCover() async throws {
        let clip = try await export(try RemuxFixtures.richMatroska(), content: .videoOnly)
        // ffprobe shows Matroska's attached cover as a picture stream.
        let streams = try FFprobe.report(clip).streams
        #expect(streams.map(\.codecType) == ["video", "subtitle", "video"])
        #expect(streams.last?.isAttachedPicture == true)
    }

    @Test(
        .enabled(if: ExternalFFmpeg.isAvailable),
        arguments: [
            (SoundSource.opus, "opus", "ogg"), (.vorbis, "ogg", "ogg"), (.mp3, "mp3", "mp3"),
            (.flac, "flac", "flac"), (.ac3, "ac3", "ac3"), (.pcmLittleEndian, "wav", "wav"),
            (.pcmBigEndian, "aiff", "aiff"), (.mp2, "mka", "matroska"), (.adts, "m4a", "mov"),
        ])
    func soundOnlyFormatFollowsTheCodec(_ fixture: SoundSource, fileExtension: String, format: String) async throws {
        let source = try fixture.make()
        let container = ExportContainer.forSource(source, mode: .fast, content: .soundOnly)
        #expect(container.fileExtension == fileExtension)
        #expect(!container.changesContainer)

        let clip = try await export(source, content: .soundOnly)
        let report = try FFprobe.report(clip)
        #expect(report.format.formatName.contains(format))
        #expect(report.streams.map(\.codecType) == ["audio"])
        let sourceCodec = try FFprobe.report(source).streams.first { $0.codecType == "audio" }?.codecName
        #expect(report.streams.first?.codecName == sourceCodec)
        #expect(abs(report.format.seconds - Self.selection) < Self.audioTolerance)
    }

    // MARK: Several sound tracks

    @Test(.enabled(if: ExternalFFmpeg.isAvailable)) func m4aKeepsEverySoundTrack() async throws {
        let clip = try await export(try SoundSource.twoAAC.make(), content: .soundOnly)
        #expect(clip.pathExtension == "m4a")
        #expect(try FFprobe.report(clip).streams.map(\.codecName) == ["aac", "aac"])
    }

    // Opus has no place in M4A, so AAC and Opus go to Matroska together, both copied.
    @Test(.enabled(if: ExternalFFmpeg.isAvailable)) func mixedSoundTracksGoToMatroska() async throws {
        let clip = try await export(try TranscodeFixtures.make(.matroskaH264), content: .soundOnly)
        #expect(clip.pathExtension == "mka")
        #expect(try FFprobe.report(clip).streams.map(\.codecName) == ["aac", "opus"])
    }

    @Test(.enabled(if: ExternalFFmpeg.isAvailable)) func singleTrackFormatKeepsTheFirst() async throws {
        let clip = try await export(try SoundSource.twoOpus.make(), content: .soundOnly)
        #expect(clip.pathExtension == "opus")
        let streams = try FFprobe.report(clip).streams
        #expect(streams.map(\.codecName) == ["opus"])
    }

    // RealAudio still goes through the re-encoding rules: into Matroska audio as AAC.
    @Test(.enabled(if: ExternalFFmpeg.isAvailable)) func realAudioIsReencodedIntoMatroska() async throws {
        let source = try RemuxFixtures.realMedia(withVideo: true)
        let request = try makeRequest(source, content: .soundOnly, range: 0...2)
        #expect(request.destination.pathExtension == "mka")
        try await drain(request)
        #expect(try FFprobe.report(request.destination).streams.map(\.codecName) == ["aac"])
    }

    // MARK: Helpers

    private func makeRequest(
        _ source: URL, content: ExportContent, mode: ExportMode = .fast, range: ClosedRange<TimeInterval> = Self.range
    ) throws -> ExportRequest {
        let container = ExportContainer.forSource(source, mode: mode, content: content)
        let destination = try TestMedia.makeTemporaryFolder().appendingPathComponent("clip.\(container.fileExtension)")
        return ExportRequest(
            source: source, range: range, mode: mode, destination: destination, estimatedSize: 1_000_000,
            content: content)
    }

    private func export(_ source: URL, content: ExportContent) async throws -> URL {
        let checksum = try ExporterTests.checksum(of: source)
        let request = try makeRequest(source, content: content)
        try await drain(request)
        #expect(try ExporterTests.checksum(of: source) == checksum)
        #expect(try ExporterTests.leftovers(in: request.destination.deletingLastPathComponent()).count == 1)
        return request.destination
    }
}

/// Videos whose sound is in a given codec, 2 s of test pattern with one or two tones.
enum SoundSource: String, CaseIterable, CustomTestStringConvertible {
    case opus, vorbis, mp3, flac, ac3, pcmLittleEndian, pcmBigEndian, mp2, adts, twoAAC, twoOpus

    var testDescription: String { rawValue }

    func make() throws -> URL {
        let tones = (0..<trackCount).flatMap { ["-f", "lavfi", "-i", "sine=frequency=\(440 * ($0 + 1)):duration=2"] }
        let maps = (0...trackCount).flatMap { ["-map", "\($0)"] }
        return try ExternalFFmpeg.make(
            "sound-\(rawValue).\(fileExtension)",
            arguments: ["-f", "lavfi", "-i", "testsrc=duration=2:size=320x180:rate=25"] + tones + maps
                + ["-c:v", videoCodec, "-g", "25"] + audioCodec + ["-threads", "1"])
    }

    private var trackCount: Int { self == .twoAAC || self == .twoOpus ? 2 : 1 }

    private var fileExtension: String {
        switch self {
        case .pcmBigEndian: "mov"
        case .mp2: "mpg"
        case .adts: "ts"
        case .twoAAC: "mp4"
        case .mp3: "avi"
        default: "mkv"
        }
    }

    private var videoCodec: String {
        switch self {
        case .mp2: "mpeg2video"
        case .mp3: "mpeg4"
        default: "libx264"
        }
    }

    private var audioCodec: [String] {
        switch self {
        case .opus, .twoOpus: ["-c:a", "libopus"]
        // FFmpeg's own Vorbis encoder is experimental and takes stereo only.
        case .vorbis: ["-c:a", "vorbis", "-strict", "-2", "-ac", "2"]
        case .mp3: ["-c:a", "libmp3lame"]
        case .flac: ["-c:a", "flac"]
        case .ac3: ["-c:a", "ac3"]
        case .pcmLittleEndian: ["-c:a", "pcm_s16le"]
        case .pcmBigEndian: ["-c:a", "pcm_s16be"]
        case .mp2: ["-c:a", "mp2"]
        case .adts, .twoAAC: ["-c:a", "aac"]
        }
    }
}
