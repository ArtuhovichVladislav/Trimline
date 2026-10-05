import CoreMedia
import Foundation
import VideoToolbox
import libavutil
import os

@testable import TrimlineCore

// Decodes a Matroska or MPEG-TS file the way the app's own player does: packets become sample buffers in
// CompressedVideoSource and VideoToolbox decodes them, a new session whenever the description changes.
enum VideoToolboxDecoding {
    struct Result {
        /// The average red of every frame, in presentation order.
        let reds: [Double]
        let failures: Int
    }

    static func reds(of url: URL) throws -> Result {
        let demuxer = try Demuxer(url: url)
        guard let stream = demuxer.streams.first(where: { $0.kind == .video }),
            let format = PlaybackVideoFormat(stream: stream, pixelAspect: AVRational(num: 1, den: 1))
        else { throw TestMediaError.writerFailed }
        let timing = StreamTiming(
            timeBase: stream.timeBase, origin: .zero, fallbackDuration: CMTime(value: 1, timescale: 25))
        let source = CompressedVideoSource(format: format, timing: timing)
        var samples: [CMSampleBuffer] = []
        let packet = try Packet()
        while try demuxer.read(into: packet) {
            guard packet.streamIndex == stream.index else { continue }
            source.append(packet, to: &samples)
        }

        let frames = Frames()
        var session: VTDecompressionSession?
        for sample in samples {
            guard let description = CMSampleBufferGetFormatDescription(sample) else { continue }
            if session.map({ !VTDecompressionSessionCanAcceptFormatDescription($0, formatDescription: description) })
                ?? true
            {
                if let session { VTDecompressionSessionInvalidate(session) }
                session = makeSession(for: description)
            }
            guard let session else {
                frames.fail()
                continue
            }
            let status = VTDecompressionSessionDecodeFrame(
                session, sampleBuffer: sample, flags: [], infoFlagsOut: nil
            ) { status, _, image, presentation, _ in
                guard status == noErr, let image else {
                    frames.fail()
                    return
                }
                frames.add(red: averageRed(of: image), at: presentation.seconds)
            }
            if status != noErr { frames.fail() }
        }
        if let session {
            VTDecompressionSessionWaitForAsynchronousFrames(session)
            VTDecompressionSessionInvalidate(session)
        }
        return frames.result
    }

    private static func makeSession(for description: CMVideoFormatDescription) -> VTDecompressionSession? {
        var session: VTDecompressionSession?
        let attributes = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA] as CFDictionary
        VTDecompressionSessionCreate(
            allocator: nil, formatDescription: description, decoderSpecification: nil,
            imageBufferAttributes: attributes, outputCallback: nil, decompressionSessionOut: &session)
        return session
    }

    private static func averageRed(of image: CVImageBuffer) -> Double {
        CVPixelBufferLockBaseAddress(image, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(image)?.assumingMemoryBound(to: UInt8.self) else { return -1 }
        let row = CVPixelBufferGetBytesPerRow(image)
        let width = CVPixelBufferGetWidth(image)
        let height = CVPixelBufferGetHeight(image)
        var sum = 0.0
        for y in stride(from: 0, to: height, by: 4) {
            for x in stride(from: 0, to: width, by: 4) {
                sum += Double(base[y * row + x * 4 + 2])
            }
        }
        return sum / Double(((height + 3) / 4) * ((width + 3) / 4))
    }

    private final class Frames: Sendable {
        private let state = OSAllocatedUnfairLock(initialState: (frames: [(Double, Double)](), failures: 0))

        func add(red: Double, at time: Double) {
            state.withLock { $0.frames.append((time, red)) }
        }

        func fail() {
            state.withLock { $0.failures += 1 }
        }

        var result: Result {
            state.withLock { state in
                Result(reds: state.frames.sorted { $0.0 < $1.0 }.map(\.1), failures: state.failures)
            }
        }
    }
}
