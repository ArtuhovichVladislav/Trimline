import AVFoundation
import Foundation
import Testing

@testable import TrimlineCore

@Suite(.serialized) struct RemuxerTests {
    private static let range: ClosedRange<TimeInterval> = 1.2...3
    private static let selection = range.upperBound - range.lowerBound
    private static let gopLength: TimeInterval = 1
    private static let audioTolerance: TimeInterval = 0.06
    private static let exactTolerance: TimeInterval = 0.05
    // FLV and MPEG-TS shift the start by the B-frame delay so decode times stay positive.
    private static let muxerStartDelay: TimeInterval = 0.1
    // Up to three 25 fps frames: the reference frames B-frames before the end depend on.
    private static let reorderTolerance: TimeInterval = 0.13

    // MARK: Containers only FFmpeg writes

    @Test(.enabled(if: ExternalFFmpeg.isAvailable), arguments: RemuxFixtures.Source.allCases)
    func copyKeepsContainerAndStreams(_ fixture: RemuxFixtures.Source) async throws {
        let source = try RemuxFixtures.make(fixture)
        let clip = try await export(source, range: Self.range)
        let report = try FFprobe.report(clip)
        let duration = report.format.seconds
        if fixture.hasVideo {
            #expect(duration >= Self.selection - Self.audioTolerance)
            #expect(duration <= Self.selection + Self.gopLength + Self.audioTolerance)
        } else {
            #expect(abs(duration - Self.selection) < Self.audioTolerance)
        }
        #expect(try FFprobe.report(source).streams.map(\.codecName) == report.streams.map(\.codecName))
        // Without an edit list the clip starts on its first packet; with one the packets before the cut are hidden.
        guard !ExportContainer.forSource(source).hasEditList else { return }
        // MPEG program streams start at the muxer's preload time, like the source; the editor counts from there.
        let start = min(report.format.start, try FFprobe.report(source).format.start)
        let first = try FFprobe.firstPacketTimes(clip, stream: fixture.hasVideo ? "v:0" : "a:0").first
        #expect(first.map { abs($0 - start) <= Self.muxerStartDelay } == true)
    }

    @Test(.enabled(if: ExternalFFmpeg.isAvailable)) func matroskaKeepsTracksSubtitlesChaptersAndTags() async throws {
        let source = try RemuxFixtures.richMatroska()
        let clip = try await export(source, range: 2.5...5)
        let original = try FFprobe.report(source)
        let report = try FFprobe.report(clip)

        #expect(report.streams.map(\.codecType) == original.streams.map(\.codecType))
        #expect(report.streams.map(\.codecName) == original.streams.map(\.codecName))
        #expect(report.streams.filter(\.isAttachedPicture).count == 1)
        #expect(
            report.streams.filter { $0.codecType == "audio" }.last?.tags?["language"] == RemuxFixtures.secondLanguage)
        #expect(report.format.tags?["title"] == RemuxFixtures.title)
        // The clip starts on the key frame at 2 s, so it holds the second and third chapters, shifted by 2 s.
        #expect(report.chapters.compactMap { $0.tags?["title"] } == Array(RemuxFixtures.chapterTitles.dropFirst()))
        #expect(report.chapters.first?.start == 0)
        #expect(abs((report.chapters.last?.end ?? 0) - 3) < Self.exactTolerance)
        #expect(abs(report.format.seconds - 3) < Self.gopLength / 2)
        #expect(try FFprobe.firstPacketTimes(clip, stream: "s:0").first.map { abs($0 - 0.2) < 0.01 } == true)
    }

    // RealMedia's codecs are re-encoded (TranscoderTests); the container change is decided here.
    @Test(.enabled(if: ExternalFFmpeg.isAvailable)) func readOnlyContainerBecomesMatroska() async throws {
        let source = try RemuxFixtures.realMedia(withVideo: false)
        let container = ExportContainer.forSource(source)
        #expect(container.changesContainer)
        #expect(container.fileExtension == "mkv")
        let clip = try await export(source, range: Self.range, fileExtension: container.fileExtension)
        #expect(try FFprobe.report(clip).format.formatName.hasPrefix("matroska"))
    }

    @Test(.enabled(if: ExternalFFmpeg.isAvailable)) func skipsStreamsTheContainerCantHold() async throws {
        let source = try RemuxFixtures.richMatroska()
        let output = try TestMedia.makeTemporaryFolder().appendingPathComponent("clip.mp4")
        let container = ExportContainer(fileExtension: "mp4", changesContainer: true, muxer: "mp4")
        let skipped = try Remuxer(source: source, container: container)
            .remux(1...3, to: output, isCancelled: { false }, progress: { _ in })
        #expect(skipped.map(\.codec) == ["subrip"])
        // The MP4 muxer adds a text track of its own for the chapters.
        let streams = try FFprobe.report(output).streams.filter { $0.codecType != "data" }
        #expect(streams.map(\.codecType) == ["video", "audio", "audio", "video"])
        #expect(streams.last?.isAttachedPicture == true)
    }

    @Test(.enabled(if: ExternalFFmpeg.isAvailable)) func rotationIsKept() async throws {
        let source = try RemuxFixtures.rotatedMovie()
        let clip = try await export(source, range: Self.range)
        let rotation = try FFprobe.report(source).streams.first?.rotation
        #expect(rotation != nil)
        #expect(try FFprobe.report(clip).streams.first?.rotation == rotation)
        let sourceTransform = try await AVURLAsset(url: source).loadTracks(withMediaType: .video).first?
            .load(.preferredTransform)
        let clipTransform = try await AVURLAsset(url: clip).loadTracks(withMediaType: .video).first?
            .load(.preferredTransform)
        #expect(clipTransform == sourceTransform)
    }

    @Test(.enabled(if: ExternalFFmpeg.isAvailable)) func cameraMetadataIsKept() async throws {
        let clip = try await export(try RemuxFixtures.cameraMovie(), range: Self.range)
        let metadata = try await AVURLAsset(url: clip).load(.commonMetadata)
        let locations = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .commonIdentifierLocation)
        #expect(try await locations.first?.load(.stringValue) == RemuxFixtures.location)
    }

    @Test(.enabled(if: ExternalFFmpeg.isAvailable)) func mp3KeepsTagsAndFrameAccuracy() async throws {
        let source = try ExternalMP3.make()
        let clip = try await export(source, range: 2...5)
        let asset = AVURLAsset(url: clip)
        #expect(abs(try await asset.load(.duration).seconds - 3) < Self.audioTolerance)
        let metadata = try await asset.load(.metadata)
        let titles = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .id3MetadataTitleDescription)
        #expect(try await titles.first?.load(.stringValue) == ExternalMP3.title)
    }

    // x264 uses B-frames: frames shown after the end may still be needed by frames before it.
    @Test(.enabled(if: ExternalFFmpeg.isAvailable)) func mp4WithBFramesIsExactAndKeepsTitle() async throws {
        let source = try RemuxFixtures.make(.mp4)
        let clip = try await export(source, range: Self.range)
        #expect(try FFprobe.report(clip).format.tags?["title"] == RemuxFixtures.title)
        let asset = AVURLAsset(url: clip)
        let video = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let shown = try await video.load(.timeRange).duration.seconds
        #expect(shown >= Self.selection - Self.exactTolerance)
        #expect(shown <= Self.selection + Self.reorderTolerance)
        let titles = AVMetadataItem.metadataItems(
            from: try await asset.load(.commonMetadata), filteredByIdentifier: .commonIdentifierTitle)
        #expect(try await titles.first?.load(.stringValue) == RemuxFixtures.title)
    }

    // MARK: Exact start through the edit list

    @Test(arguments: [AVFileType.mov, .mp4])
    func editListStartsExactlyBetweenKeyframes(_ fileType: AVFileType) async throws {
        let spec = TestMedia.VideoSpec(duration: 4, frameRate: 30, keyframeInterval: 90, fileType: fileType)
        let source = try await TestMedia.video(spec)
        let clip = try await export(source, range: 1.5...3)
        let asset = AVURLAsset(url: clip)
        #expect(abs(try await asset.load(.duration).seconds - 1.5) < Self.exactTolerance)
        let original = AVURLAsset(url: source)
        let expected = try await Self.averageRed(of: original, at: 1.5)
        let keyframe = try await Self.averageRed(of: original, at: 0)
        let shown = try await Self.averageRed(of: asset, at: 0)
        #expect(abs(shown - expected) < Self.redPerFrame / 2)
        #expect(abs(shown - keyframe) > Self.redPerFrame)
    }

    // MARK: Helpers

    private func export(
        _ source: URL, range: ClosedRange<TimeInterval>, fileExtension: String? = nil
    ) async throws -> URL {
        let checksum = try ExporterTests.checksum(of: source)
        let base = try makeRequest(source, range: range)
        let destination =
            fileExtension.map {
                base.destination.deletingPathExtension().appendingPathExtension($0)
            } ?? base.destination
        let request = ExportRequest(
            source: source, range: range, mode: .fast, destination: destination, estimatedSize: base.estimatedSize)
        try await drain(request)
        #expect(try ExporterTests.checksum(of: source) == checksum)
        #expect(
            try ExporterTests.leftovers(in: destination.deletingLastPathComponent()) == [destination.lastPathComponent])
        return destination
    }

    // TestMedia paints frame n with red = 8n, the same over the whole picture.
    private static let redPerFrame = 8.0

    private static func averageRed(of asset: AVURLAsset, at seconds: TimeInterval) async throws -> Double {
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let image = try await generator.image(at: time).image
        let width = 8
        let height = 8
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try #require(
            CGContext(
                data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let reds = stride(from: 0, to: pixels.count, by: 4).map { Double(pixels[$0]) }
        return reds.reduce(0, +) / Double(reds.count)
    }
}
