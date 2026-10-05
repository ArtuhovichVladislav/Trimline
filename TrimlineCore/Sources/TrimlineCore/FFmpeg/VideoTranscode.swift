import Foundation
import libavcodec
import libavutil
import libswscale

/// Decodes from the key frame before the start, drops the frames shown before it and encodes the rest.
final class VideoTranscode: TranscodedTrack {
    let inputIndex: Int
    private(set) var isFinished = false
    private let decoder: Decoder
    private let output: any EncodedVideoOutput
    private let converter: FrameConverter
    private let frame: Frame
    private let reportsProgress: Bool
    private let span: TranscodeSpan
    private let timeBase: AVRational
    private let origin: Int64
    private let end: Int64
    private let tolerance: Int64
    private let frameDuration: Int64
    private var nextPts = FFmpegTime.noValue
    private var lastOutputPts = FFmpegTime.noValue

    // A start a hair before a frame boundary means the frame that begins there.
    private static let boundaryTolerance: TimeInterval = 0.000_5
    // Every frame thread of the decoder holds about this many pictures of its own (measured with 4K HEVC,
    // the worst case); the budget keeps precise saving within the 400 MB target in docs/spec.md.
    private static let picturesPerDecoderThread = 6.0
    private static let decoderThreadBudget = 160.0 * 1024 * 1024

    convenience init(
        stream: Demuxer.Stream, in demuxer: Demuxer, encoding: Encoding, output clip: RemuxOutput,
        span: TranscodeSpan, reportsProgress: Bool
    ) throws(FFmpegError) {
        guard let source = demuxer.stream(stream.index) else { throw .invalidData }
        let settings = VideoEncoderSettings(stream: stream, in: demuxer, encoding: encoding)
        let (encoder, _) = try settings.makeEncoder(for: source, globalHeader: clip.needsGlobalHeader)
        try self.init(
            stream: stream, output: try EncodedStream(encoder: encoder, source: source, output: clip), span: span,
            reportsProgress: reportsProgress)
    }

    init(stream: Demuxer.Stream, output: any EncodedVideoOutput, span: TranscodeSpan, reportsProgress: Bool)
        throws(FFmpegError)
    {
        inputIndex = stream.index
        decoder = try Decoder(stream: stream, threadCount: Self.decoderThreads(for: stream))
        self.output = output
        let encoder = output.encoder.context.pointee
        converter = FrameConverter(
            format: encoder.pix_fmt, width: encoder.width, height: encoder.height,
            isFullRange: encoder.color_range == AVCOL_RANGE_JPEG)
        frame = try Frame()
        self.reportsProgress = reportsProgress
        self.span = span
        timeBase = stream.timeBase
        origin = FFmpegTime.timestamp(span.origin, in: timeBase)
        end = FFmpegTime.timestamp(span.end, in: timeBase)
        tolerance = FFmpegTime.timestamp(Self.boundaryTolerance, in: timeBase)
        let rate = stream.frameRate ?? VideoEncoderSettings.fallbackFrameRate
        frameDuration = max(1, FFmpegTime.timestamp(1 / rate, in: timeBase))
    }

    func process(_ packet: Packet, isCancelled: Remuxer.Cancellation, progress: Remuxer.Progress) throws(FFmpegError) {
        guard !isFinished else { return }
        try decoder.sendTolerantly(packet)
        try receiveFrames(isCancelled: isCancelled, progress: progress)
    }

    func finish(progress: Remuxer.Progress) throws(FFmpegError) {
        if !isFinished {
            try decoder.sendTolerantly(nil)
            try receiveFrames(isCancelled: { false }, progress: progress)
            isFinished = true
        }
        try output.send(nil)
    }

    // MARK: Private

    /// Frame threads speed up decoding, but each holds whole pictures: 4K gets one or two, HD most cores.
    private static func decoderThreads(for stream: Demuxer.Stream) -> Int32 {
        let format = AVPixelFormat(rawValue: stream.parameters.pointee.format)
        let depth = av_pix_fmt_desc_get(format).map { Int($0.pointee.comp.0.depth) } ?? 8
        let bytesPerSample = depth > 8 ? 2.0 : 1.0
        let pictureBytes = Double(stream.width * stream.height) * 1.5 * bytesPerSample
        guard pictureBytes > 0 else { return 0 }
        let affordable = Int(decoderThreadBudget / (pictureBytes * picturesPerDecoderThread))
        return Int32(affordable.clamped(to: 1...ProcessInfo.processInfo.activeProcessorCount))
    }

    private func receiveFrames(isCancelled: Remuxer.Cancellation, progress: Remuxer.Progress) throws(FFmpegError) {
        while !isFinished, try decoder.receiveTolerantly(into: frame) {
            defer { frame.unref() }
            guard !isCancelled() else { throw RemuxStop.cancelled }
            try encodeIfShown(frame, progress: progress)
        }
    }

    private func encodeIfShown(_ frame: Frame, progress: Remuxer.Progress) throws(FFmpegError) {
        let reported = frame.bestEffortTimestamp
        let pts = reported != FFmpegTime.noValue ? reported : nextPts
        guard pts != FFmpegTime.noValue else { return }
        let duration = frame.pointer.pointee.duration > 0 ? frame.pointer.pointee.duration : frameDuration
        nextPts = try FFmpegTime.sum(pts, duration)
        if pts >= (try FFmpegTime.difference(end, tolerance)) {
            isFinished = true
            return
        }
        guard nextPts > (try FFmpegTime.sum(origin, tolerance)) else { return }

        let converted = try converter.convert(frame)
        var outputPts = max(0, try FFmpegTime.difference(pts, origin))
        if lastOutputPts != FFmpegTime.noValue, outputPts <= lastOutputPts {
            outputPts = try FFmpegTime.sum(lastOutputPts, 1)
        }
        lastOutputPts = outputPts
        converted.pointer.pointee.pts = outputPts
        converted.pointer.pointee.pict_type = AV_PICTURE_TYPE_NONE
        try output.send(converted)
        if reportsProgress, let shown = FFmpegTime.seconds(outputPts, in: timeBase) {
            progress(shown / span.length)
        }
    }
}

/// Brings decoded frames to the encoder's pixel format and size, keeping the source's range.
final class FrameConverter {
    private let format: AVPixelFormat
    private let width: Int32
    private let height: Int32
    private let isFullRange: Bool
    private var context: OpaquePointer?
    private var converted: Frame?
    private var sourceSignature: [Int32] = []

    init(format: AVPixelFormat, width: Int32, height: Int32, isFullRange: Bool) {
        self.format = format
        self.width = width
        self.height = height
        self.isFullRange = isFullRange
    }

    deinit {
        sws_freeContext(context)
    }

    /// Returns `frame` itself when it already fits.
    func convert(_ frame: Frame) throws(FFmpegError) -> Frame {
        let source = frame.pointer.pointee
        let sourceFormat = AVPixelFormat(rawValue: source.format)
        // YUVJ is YUV with a full-range flag; the bytes need no conversion.
        if sourceFormat == AV_PIX_FMT_YUVJ420P, format == AV_PIX_FMT_YUV420P {
            frame.pointer.pointee.format = format.rawValue
            frame.pointer.pointee.color_range = AVCOL_RANGE_JPEG
        }
        if frame.pointer.pointee.format == format.rawValue, source.width == width, source.height == height {
            return frame
        }
        try configure(for: frame)
        let target: Frame
        if let converted {
            target = converted
        } else {
            target = try Frame()
            converted = target
        }
        target.unref()
        target.pointer.pointee.format = format.rawValue
        target.pointer.pointee.width = width
        target.pointer.pointee.height = height
        try FFmpegError.check(av_frame_get_buffer(target.pointer, 0))
        try FFmpegError.check(av_frame_copy_props(target.pointer, frame.pointer))
        try FFmpegError.check(sws_scale_frame(context, target.pointer, frame.pointer))
        return target
    }

    private func configure(for frame: Frame) throws(FFmpegError) {
        let source = frame.pointer.pointee
        let signature = [source.width, source.height, source.format]
        guard signature != sourceSignature || context == nil else { return }
        sws_freeContext(context)
        context = sws_getContext(
            source.width, source.height, AVPixelFormat(rawValue: source.format),
            width, height, format, SWS_BILINEAR, nil, nil, nil)
        guard let context else { throw .invalidData }
        sourceSignature = signature
        let range: Int32 = isFullRange ? 1 : 0
        let coefficients = sws_getCoefficients(SWS_CS_DEFAULT)
        let unity: Int32 = 1 << 16
        sws_setColorspaceDetails(context, coefficients, range, coefficients, range, 0, unity, unity)
    }
}

extension Decoder {
    /// A damaged packet costs a frame, not the whole clip.
    func sendTolerantly(_ packet: Packet?) throws(FFmpegError) {
        do throws(FFmpegError) {
            try send(packet)
        } catch {
            guard error.code == FFmpegError.invalidData.code else { throw error }
        }
    }

    func receiveTolerantly(into frame: Frame) throws(FFmpegError) -> Bool {
        do throws(FFmpegError) {
            return try receive(into: frame)
        } catch {
            guard error.code == FFmpegError.invalidData.code else { throw error }
            return false
        }
    }
}
