import CoreVideo
import Foundation
import Testing

@testable import TrimlineCore

@Suite(.enabled(if: ExternalFFmpeg.isAvailable)) struct DemuxerTests {
    @Test func opensMatroskaAndReadsPackets() throws {
        let url = try ExternalFFmpeg.testMovie("vp9.mkv", codec: ["-c:v", "libvpx-vp9", "-c:a", "libopus"])
        let demuxer = try Demuxer(url: url)
        #expect(demuxer.formatName.contains("matroska"))
        #expect(demuxer.streams.map(\.kind) == [.video, .audio])
        #expect(demuxer.streams[0].codecName == "vp9")
        #expect(demuxer.streams[1].codecName == "opus")
        #expect(abs((demuxer.duration ?? 0) - 4) < 0.1)

        let packet = try Packet()
        var count = 0
        while try demuxer.read(into: packet) { count += 1 }
        #expect(count > 100)
    }

    @Test func decodesVideoFrames() throws {
        let url = try ExternalFFmpeg.testMovie("vp9.mkv", codec: ["-c:v", "libvpx-vp9", "-c:a", "libopus"])
        let demuxer = try Demuxer(url: url)
        let decoder = try Decoder(stream: demuxer.streams[0])
        let packet = try Packet()
        let frame = try Frame()
        var frames = 0
        var width = 0
        while try demuxer.read(into: packet) {
            guard packet.streamIndex == 0 else { continue }
            try decoder.send(packet)
            while try decoder.receive(into: frame) {
                frames += 1
                width = frame.width
            }
        }
        try decoder.send(nil)
        while try decoder.receive(into: frame) { frames += 1 }
        #expect(frames == 100)
        #expect(width == 320)
    }

    @Test func garbageFailsToOpen() throws {
        #expect(throws: FFmpegError.self) { try Demuxer(url: try TestMedia.garbage(extension: "mkv")) }
    }
}

@Suite(.enabled(if: ExternalFFmpeg.isAvailable)) struct ConversionTests {
    @Test func resamplesOpusToStereoFloat() throws {
        let url = try ExternalFFmpeg.testMovie("vp9.mkv", codec: ["-c:v", "libvpx-vp9", "-c:a", "libopus"])
        let demuxer = try Demuxer(url: url)
        let decoder = try Decoder(stream: demuxer.streams[1])
        let resampler = Resampler(outputSampleRate: 44_100, outputChannels: 2)
        let packet = try Packet()
        let frame = try Frame()
        var samples: [Float] = []
        while try demuxer.read(into: packet) {
            guard packet.streamIndex == 1 else { continue }
            try decoder.send(packet)
            while try decoder.receive(into: frame) { try resampler.convert(frame, appendingTo: &samples) }
        }
        let seconds = Double(samples.count / 2) / 44_100
        #expect(abs(seconds - 4) < 0.1)
        // lavfi sine defaults to amplitude 1/8.
        #expect((samples.max() ?? 0) > 0.05)
    }

    @Test func scalesFrameToBGRA() throws {
        let url = try ExternalFFmpeg.testMovie("vp9.mkv", codec: ["-c:v", "libvpx-vp9", "-c:a", "libopus"])
        let demuxer = try Demuxer(url: url)
        let decoder = try Decoder(stream: demuxer.streams[0])
        let packet = try Packet()
        let frame = try Frame()
        var gotFrame = false
        while !gotFrame, try demuxer.read(into: packet) {
            guard packet.streamIndex == 0 else { continue }
            try decoder.send(packet)
            gotFrame = try decoder.receive(into: frame)
        }
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, 160, 90, kCVPixelFormatType_32BGRA, nil, &buffer)
        let pixelBuffer = try #require(buffer)
        try Scaler().scale(frame, into: pixelBuffer)
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        let base = try #require(CVPixelBufferGetBaseAddress(pixelBuffer)).assumingMemoryBound(to: UInt8.self)
        // testsrc starts with white-ish bars on the right; the image must not be all black.
        let bytes = UnsafeBufferPointer(start: base, count: CVPixelBufferGetBytesPerRow(pixelBuffer) * 90)
        #expect(bytes.contains { $0 > 128 })
    }
}
