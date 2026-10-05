import CoreGraphics
import CoreMedia
import CoreVideo

/// Decodes everything VideoToolbox can't take (VP9, AV1, MPEG-4, WMV…) with libavcodec into BGRA frames.
final class DecodedVideoSource: PlaybackSource {
    // A preview never needs more than a full HD frame, and keeping frames small keeps the queue in budget.
    private static let maximumPixelCount = 1920.0 * 1080
    private static let queuedFramesMemoryBudget = 48.0 * 1024 * 1024
    private static let bytesPerPixel = 4.0
    private static let lookaheadLimits: ClosedRange<TimeInterval> = 0.1...0.5

    let lookahead: TimeInterval

    private let decoder: Decoder
    private let scaler = Scaler()
    private let frame: Frame
    private let pool: CVPixelBufferPool
    private let timing: StreamTiming
    private var format: CMVideoFormatDescription?
    private var start = CMTime.zero
    private var awaitsFirstShownFrame = true
    private var nextFrameTime: CMTime?

    init(stream: Demuxer.Stream, displaySize: CGSize, timing: StreamTiming) throws(FFmpegError) {
        decoder = try Decoder(stream: stream)
        frame = try Frame()
        self.timing = timing

        let scale = min(1, (Self.maximumPixelCount / max(1, displaySize.width * displaySize.height)).squareRoot())
        let width = Self.evenPixels(displaySize.width * scale)
        let height = Self.evenPixels(displaySize.height * scale)
        guard let pool = Self.makePool(width: width, height: height) else { throw .outOfMemory }
        self.pool = pool

        let frameBytes = Double(width * height) * Self.bytesPerPixel
        let budget = (Self.queuedFramesMemoryBudget / frameBytes).rounded(.down) * timing.fallbackDuration.seconds
        lookahead = min(max(budget, Self.lookaheadLimits.lowerBound), Self.lookaheadLimits.upperBound)
    }

    func restart(at start: CMTime) {
        decoder.flush()
        self.start = start
        awaitsFirstShownFrame = true
        nextFrameTime = nil
    }

    func append(_ packet: Packet, to output: inout [CMSampleBuffer]) {
        // A broken packet costs one frame; the decoder recovers at the next key frame.
        try? decoder.send(packet)
        receiveFrames(to: &output)
    }

    func drain(to output: inout [CMSampleBuffer]) {
        try? decoder.send(nil)
        receiveFrames(to: &output)
    }

    private func receiveFrames(to output: inout [CMSampleBuffer]) {
        while (try? decoder.receive(into: frame)) == true {
            if let sample = makeSample() {
                output.append(sample)
            }
        }
    }

    private func makeSample() -> CMSampleBuffer? {
        let presentation = timing.time(frame.bestEffortTimestamp) ?? nextFrameTime ?? start
        let duration = timing.duration(frame.pointer.pointee.duration)
        nextFrameTime = presentation + duration
        // Frames before a precise seek target are decoded only to reach it; skipping them before scaling is cheap.
        guard presentation + duration > start else { return nil }

        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
        guard let pixelBuffer, (try? scaler.scale(frame, into: pixelBuffer)) != nil,
            let format = format(for: pixelBuffer)
        else { return nil }

        var timingInfo = CMSampleTimingInfo(
            duration: duration, presentationTimeStamp: presentation, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(
            allocator: nil, imageBuffer: pixelBuffer, formatDescription: format, sampleTiming: &timingInfo,
            sampleBufferOut: &sample)
        guard let sample else { return nil }
        if awaitsFirstShownFrame {
            awaitsFirstShownFrame = false
            if presentation > start {
                PlaybackBuffers.setAttachment(kCMSampleAttachmentKey_DisplayImmediately, on: sample)
            }
        }
        return sample
    }

    private func format(for pixelBuffer: CVPixelBuffer) -> CMVideoFormatDescription? {
        if let format, CMVideoFormatDescriptionMatchesImageBuffer(format, imageBuffer: pixelBuffer) {
            return format
        }
        CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: nil, imageBuffer: pixelBuffer, formatDescriptionOut: &format)
        return format
    }

    private static func evenPixels(_ value: CGFloat) -> Int {
        max(2, Int(value / 2) * 2)
    }

    private static func makePool(width: Int, height: Int) -> CVPixelBufferPool? {
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any](),
        ]
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
        return pool
    }
}
