import CoreMedia
import Foundation
import Testing
import VideoToolbox

@testable import TrimlineCore

// The VP9, Ogg and rotated files are shared with the engine tests, so each is encoded once per run.
enum PlaybackFixtures {
    static func vp9MKV() throws -> URL {
        try FFmpegFixtures.vp9MKV.make()
    }

    // testsrc is RGB, which libx264 would keep as 4:4:4; VideoToolbox only takes 4:2:0 and 4:2:2.
    static func h264MKV() throws -> URL {
        try ExternalFFmpeg.testMovie(
            "playback-h264.mkv", codec: ["-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac"])
    }

    static func h264TS() throws -> URL {
        try ExternalFFmpeg.testMovie(
            "playback-h264.ts", codec: ["-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", "-f", "mpegts"])
    }

    static func oggVorbis() throws -> URL {
        try FFmpegFixtures.oggVorbis.make()
    }

    static func rotatedMKV() throws -> URL {
        try FFmpegFixtures.rotatedMKV()
    }

    static func notMedia() throws -> URL {
        let url = try TestMedia.makeTemporaryFolder().appendingPathComponent("notes.mkv")
        try Data("Not a movie at all.".utf8).write(to: url)
        return url
    }

    static func info(for url: URL, kind: MediaKind) -> MediaInfo {
        MediaInfo(
            url: url, kind: kind, duration: 4, fileSize: 0,
            displaySize: kind == .video ? CGSize(width: 320, height: 180) : nil,
            frameRate: kind == .video ? 25 : nil, estimatedBitRate: 0)
    }
}

@Suite(.enabled(if: ExternalFFmpeg.isAvailable)) struct FFmpegPlaybackPipelineTests {
    private static let frameStep = 1.0 / 25

    @Test func passesH264ThroughCompressed() async throws {
        let pipeline = PlaybackPipeline(url: try PlaybackFixtures.h264MKV(), includesVideo: true)
        let layout = try #require(await pipeline.open())
        #expect(layout.tracks == [.video, .audio])
        let seek = await pipeline.seek(to: 0, precise: true)
        let samples = await Self.samples(.video, count: 30, from: pipeline, generation: seek.generation)

        #expect(samples.count == 30)
        #expect(samples.allSatisfy { CMSampleBufferGetImageBuffer($0) == nil })
        #expect(samples.allSatisfy { $0.formatDescription?.mediaSubType.rawValue == kCMVideoCodecType_H264 })
        let presentation = samples.map(\.presentationTimeStamp.seconds).sorted()
        #expect(abs(presentation[0]) < 0.001)
        #expect(zip(presentation, presentation.dropFirst()).allSatisfy { abs($1 - $0 - Self.frameStep) < 0.002 })
    }

    @Test func rewritesStartCodesFromTransportStream() async throws {
        let pipeline = PlaybackPipeline(url: try PlaybackFixtures.h264TS(), includesVideo: true)
        #expect(await pipeline.open() != nil)
        let seek = await pipeline.seek(to: 0, precise: true)
        let samples = await Self.samples(.video, count: 10, from: pipeline, generation: seek.generation)

        #expect(samples.count == 10)
        #expect(samples.allSatisfy { $0.formatDescription?.mediaSubType.rawValue == kCMVideoCodecType_H264 })
        for sample in samples {
            #expect(Self.isLengthPrefixed(try #require(sample.dataBuffer)))
        }
        // The transport stream clock starts well above zero; the timeline must not.
        #expect(abs(samples[0].presentationTimeStamp.seconds) < 0.2)
    }

    @Test func decodesVP9IntoPixelBuffers() async throws {
        let pipeline = PlaybackPipeline(url: try PlaybackFixtures.vp9MKV(), includesVideo: true)
        let layout = try #require(await pipeline.open())
        #expect(layout.tracks == [.video, .audio])
        let seek = await pipeline.seek(to: 0, precise: true)
        let samples = await Self.samples(.video, count: 30, from: pipeline, generation: seek.generation)

        #expect(samples.count == 30)
        let pixelBuffer = try #require(samples.first.flatMap(CMSampleBufferGetImageBuffer))
        #expect(CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA)
        #expect(CVPixelBufferGetIOSurface(pixelBuffer) != nil)
        Self.expectIncreasing(samples.map(\.presentationTimeStamp.seconds))
    }

    @Test(arguments: [PlaybackFixtures.vp9MKV, PlaybackFixtures.h264MKV, PlaybackFixtures.h264TS])
    func preciseSeekStartsAtFrameCoveringTarget(_ fixture: () throws -> URL) async throws {
        let pipeline = PlaybackPipeline(url: try fixture(), includesVideo: true)
        _ = await pipeline.open()
        let seek = await pipeline.seek(to: 2.5, precise: true)
        #expect(seek.time == 2.5)
        let samples = await Self.samples(.video, count: 40, from: pipeline, generation: seek.generation)
        // Compressed samples come in decode order, so the earliest shown one is what appears first.
        let shown = samples.filter { !Self.hasAttachment(kCMSampleAttachmentKey_DoNotDisplay, $0) }
        let first = try #require(shown.min { $0.presentationTimeStamp < $1.presentationTimeStamp })
        let start = first.presentationTimeStamp.seconds
        #expect(start <= 2.5 && 2.5 < start + first.duration.seconds + 0.001)
    }

    @Test(arguments: [PlaybackFixtures.h264MKV, PlaybackFixtures.h264TS])
    func compressedSamplesDecodeWithVideoToolbox(_ fixture: () throws -> URL) async throws {
        let pipeline = PlaybackPipeline(url: try fixture(), includesVideo: true)
        _ = await pipeline.open()
        let seek = await pipeline.seek(to: 1.5, precise: false)
        let samples = await Self.samples(.video, count: 10, from: pipeline, generation: seek.generation)
        #expect(try Self.decodedImageCount(samples) == samples.count)
    }

    @Test func fastSeekLandsOnKeyframe() async throws {
        for url in [try PlaybackFixtures.vp9MKV(), try PlaybackFixtures.h264MKV()] {
            let pipeline = PlaybackPipeline(url: url, includesVideo: true)
            _ = await pipeline.open()
            let seek = await pipeline.seek(to: 2.6, precise: false)
            #expect(abs(seek.time - 2) < 0.001)
            let first = try #require(await pipeline.nextSample(for: .video, generation: seek.generation))
            #expect(abs(first.presentationTime - 2) < 0.001)
        }
    }

    @Test func audioIsContinuousFromSeekTarget() async throws {
        let pipeline = PlaybackPipeline(url: try PlaybackFixtures.oggVorbis(), includesVideo: false)
        let layout = try #require(await pipeline.open())
        #expect(layout.tracks == [.audio])
        let seek = await pipeline.seek(to: 1.25, precise: true)
        let samples = await Self.samples(.audio, count: 20, from: pipeline, generation: seek.generation)

        #expect(samples.count == 20)
        #expect(abs(samples[0].presentationTimeStamp.seconds - 1.25) < 0.001)
        for (sample, next) in zip(samples, samples.dropFirst()) {
            let end = sample.presentationTimeStamp + sample.duration
            #expect(abs((next.presentationTimeStamp - end).seconds) < 0.0001)
        }
    }

    @Test func staleGenerationGetsNothing() async throws {
        let pipeline = PlaybackPipeline(url: try PlaybackFixtures.vp9MKV(), includesVideo: true)
        _ = await pipeline.open()
        let old = await pipeline.seek(to: 0, precise: true)
        let new = await pipeline.seek(to: 1, precise: true)
        #expect(await pipeline.nextSample(for: .video, generation: old.generation) == nil)
        #expect(await pipeline.nextSample(for: .video, generation: new.generation) != nil)
    }

    @Test func endsAtEndOfFile() async throws {
        let pipeline = PlaybackPipeline(url: try PlaybackFixtures.h264MKV(), includesVideo: true)
        _ = await pipeline.open()
        let seek = await pipeline.seek(to: 3.5, precise: true)
        let samples = await Self.samples(.video, count: 1000, from: pipeline, generation: seek.generation)
        #expect((10...30).contains(samples.count))
    }

    @Test func garbageDoesNotOpen() async throws {
        let pipeline = PlaybackPipeline(url: try PlaybackFixtures.notMedia(), includesVideo: true)
        #expect(await pipeline.open() == nil)
    }

    private static func samples(
        _ track: PlaybackTrack, count: Int, from pipeline: PlaybackPipeline, generation: Int
    ) async -> [CMSampleBuffer] {
        var samples: [CMSampleBuffer] = []
        while samples.count < count, let sample = await pipeline.nextSample(for: track, generation: generation) {
            samples.append(sample.buffer)
        }
        return samples
    }

    private static func hasAttachment(_ key: CFString, _ sample: CMSampleBuffer) -> Bool {
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [NSDictionary]
        return attachments?.first?[key] as? Bool == true
    }

    private final class ImageCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        var count: Int { lock.withLock { value } }
        func add() { lock.withLock { value += 1 } }
    }

    private static func decodedImageCount(_ samples: [CMSampleBuffer]) throws -> Int {
        let format = try #require(samples.first?.formatDescription)
        var created: VTDecompressionSession?
        VTDecompressionSessionCreate(
            allocator: nil, formatDescription: format, decoderSpecification: nil, imageBufferAttributes: nil,
            outputCallback: nil, decompressionSessionOut: &created)
        let session = try #require(created)
        defer { VTDecompressionSessionInvalidate(session) }
        let counter = ImageCounter()
        for sample in samples {
            VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) {
                status, _, image, _, _ in
                if status == noErr, image != nil { counter.add() }
            }
        }
        VTDecompressionSessionWaitForAsynchronousFrames(session)
        return counter.count
    }

    private static func expectIncreasing(_ values: [Double]) {
        #expect(zip(values, values.dropFirst()).allSatisfy { $0 < $1 })
    }

    private static func isLengthPrefixed(_ block: CMBlockBuffer) -> Bool {
        var data = [UInt8](repeating: 0, count: CMBlockBufferGetDataLength(block))
        CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: data.count, destination: &data)
        var offset = 0
        while offset + PlaybackNALUnits.lengthPrefixSize <= data.count {
            let length = data[offset..<offset + PlaybackNALUnits.lengthPrefixSize].reduce(0) { $0 << 8 | Int($1) }
            guard length > 0 else { return false }
            offset += PlaybackNALUnits.lengthPrefixSize + length
        }
        return offset == data.count
    }
}

@Suite struct PlaybackNALUnitsTests {
    @Test func rewritesStartCodesAsLengths() {
        let annexB: [UInt8] = [0, 0, 0, 1, 0x67, 1, 2, 0, 0, 1, 0x68, 3, 0, 0, 0, 1, 0x65, 4, 5, 6]
        let converted = annexB.withUnsafeBytes { PlaybackNALUnits.lengthPrefixed(fromAnnexB: $0) }
        #expect(converted == [0, 0, 0, 3, 0x67, 1, 2, 0, 0, 0, 2, 0x68, 3, 0, 0, 0, 4, 0x65, 4, 5, 6])
    }

    @Test func recognisesAnnexB() {
        #expect(PlaybackNALUnits.isAnnexB([0, 0, 1, 0x67]))
        #expect(PlaybackNALUnits.isAnnexB([0, 0, 0, 1, 0x67]))
        #expect(!PlaybackNALUnits.isAnnexB([1, 0x64, 0, 0x1F]))
    }
}
