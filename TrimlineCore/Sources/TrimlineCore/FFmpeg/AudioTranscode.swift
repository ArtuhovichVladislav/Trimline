import Foundation
import libavcodec
import libavutil
import libswresample

/// Decodes sound the clip's container can't hold, cuts it at the exact sample and encodes it again.
/// Sample positions come from the timestamps until the clip starts and from counting after that,
/// so files with broken audio timestamps still get continuous sound.
final class AudioTranscode: TranscodedTrack {
    let inputIndex: Int
    private(set) var isFinished = false
    private let decoder: Decoder
    private let output: EncodedStream
    private let converter: SampleConverter
    private let fifo: SampleFIFO
    private let decoded: Frame
    private let reportsProgress: Bool
    private let span: TranscodeSpan
    private let timeBase: AVRational
    private let sampleRate: Int32
    private let frameSize: Int32
    private let endSample: Int64
    private var nextPosition: Int64?
    private var estimatedPosition: Int64 = 0
    private var sentSamples: Int64 = 0

    private static let aacBitRatePerChannel: Int64 = 64_000
    private static let aacSampleRates: [Int32] = [8000, 11025, 12000, 16000, 22050, 24000, 32000, 44100, 48000]
    private static let flacHighBitDepth: Int32 = 24
    private static let fallbackFrameSize: Int32 = 1024

    init(
        stream: Demuxer.Stream, in demuxer: Demuxer, encoding: Encoding, output clip: RemuxOutput,
        span: TranscodeSpan, reportsProgress: Bool
    ) throws(FFmpegError) {
        guard let source = demuxer.stream(stream.index) else { throw .invalidData }
        inputIndex = stream.index
        decoder = try Decoder(stream: stream)
        let format = Self.sampleFormat(for: encoding, decoding: decoder.context.pointee.sample_fmt)
        let rate = Self.sampleRate(for: encoding, source: decoder.context.pointee.sample_rate)
        var layout = Self.channelLayout(for: encoding, source: decoder.context.pointee.ch_layout)
        defer { av_channel_layout_uninit(&layout) }
        let encoder = try Encoder(name: encoding.encoder) { context in
            context.pointee.sample_fmt = format
            context.pointee.sample_rate = rate
            context.pointee.time_base = AVRational(num: 1, den: rate)
            av_channel_layout_copy(&context.pointee.ch_layout, &layout)
            if encoding == .aac {
                context.pointee.bit_rate = Self.aacBitRatePerChannel * Int64(layout.nb_channels)
            } else if format == AV_SAMPLE_FMT_S32 {
                context.pointee.bits_per_raw_sample = Self.flacHighBitDepth
            }
            if clip.needsGlobalHeader {
                context.pointee.flags |= Int32(AV_CODEC_FLAG_GLOBAL_HEADER)
            }
        }
        output = try EncodedStream(encoder: encoder, source: source, output: clip)
        converter = try SampleConverter(format: format, sampleRate: rate, layout: layout)
        let size = encoder.context.pointee.frame_size
        frameSize = size > 0 ? size : Self.fallbackFrameSize
        fifo = try SampleFIFO(format: format, layout: layout, sampleRate: rate, capacity: frameSize)
        decoded = try Frame()
        self.reportsProgress = reportsProgress
        self.span = span
        timeBase = stream.timeBase
        sampleRate = rate
        endSample = FFmpegTime.rounded(span.length * Double(rate)) ?? .max
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
        if fifo.count > 0 {
            try encodeFrame(of: fifo.count, progress: progress)
        }
        try output.send(nil)
    }

    // MARK: Private

    private func receiveFrames(isCancelled: Remuxer.Cancellation, progress: Remuxer.Progress) throws(FFmpegError) {
        while !isFinished, try decoder.receiveTolerantly(into: decoded) {
            defer { decoded.unref() }
            guard !isCancelled() else { throw RemuxStop.cancelled }
            try keepSamples(of: try converter.convert(decoded))
            while fifo.count >= frameSize {
                try encodeFrame(of: frameSize, progress: progress)
            }
        }
    }

    private func keepSamples(of converted: Frame) throws(FFmpegError) {
        let count = Int64(converted.sampleCount)
        guard count > 0 else { return }
        let position = nextPosition ?? timestampPosition() ?? estimatedPosition
        let next = try FFmpegTime.sum(position, count)
        estimatedPosition = next
        let first = max(position, 0)
        let last = min(next, endSample)
        if last > first {
            try fifo.write(converted, from: Int(try FFmpegTime.difference(first, position)), count: Int(last - first))
            nextPosition = next
        }
        if next >= endSample {
            isFinished = true
        }
    }

    private func timestampPosition() -> Int64? {
        guard let seconds = FFmpegTime.seconds(decoded.bestEffortTimestamp, in: timeBase) else { return nil }
        return FFmpegTime.rounded((seconds - span.origin) * Double(sampleRate))
    }

    private func encodeFrame(of count: Int32, progress: Remuxer.Progress) throws(FFmpegError) {
        let frame = try fifo.read(count)
        frame.pointer.pointee.pts = sentSamples
        sentSamples += Int64(count)
        try output.send(frame)
        if reportsProgress {
            progress(Double(sentSamples) / Double(sampleRate) / span.length)
        }
    }

    private static func sampleFormat(for encoding: Encoding, decoding: AVSampleFormat) -> AVSampleFormat {
        encoding == .flac && av_get_bytes_per_sample(decoding) > 2 ? AV_SAMPLE_FMT_S32 : AV_SAMPLE_FMT_S16
    }

    private static func sampleRate(for encoding: Encoding, source: Int32) -> Int32 {
        guard encoding == .aac else { return source }
        return aacSampleRates.first { $0 >= source } ?? aacSampleRates.last ?? source
    }

    /// The source's layout when the encoder takes it, stereo otherwise.
    private static func channelLayout(for encoding: Encoding, source: AVChannelLayout) -> AVChannelLayout {
        var layout = AVChannelLayout()
        var input = source
        if input.order == AV_CHANNEL_ORDER_NATIVE {
            av_channel_layout_copy(&layout, &input)
        } else {
            av_channel_layout_default(&layout, input.nb_channels)
        }
        guard let codec = avcodec_find_encoder_by_name(encoding.encoder) else { return layout }
        var configs: UnsafeRawPointer?
        var count: Int32 = 0
        let result = avcodec_get_supported_config(nil, codec, AV_CODEC_CONFIG_CHANNEL_LAYOUT, 0, &configs, &count)
        guard result >= 0, let configs else { return layout }
        let supported = configs.assumingMemoryBound(to: AVChannelLayout.self)
        if (0..<Int(count)).contains(where: { av_channel_layout_compare(&layout, supported + $0) == 0 }) {
            return layout
        }
        av_channel_layout_uninit(&layout)
        av_channel_layout_default(&layout, 2)
        return layout
    }
}

/// Converts decoded audio to the encoder's sample format, rate and layout.
final class SampleConverter {
    private let output: Frame
    private let format: AVSampleFormat
    private let sampleRate: Int32
    private var layout = AVChannelLayout()
    private var context: OpaquePointer?
    private var signature: [Int32] = []

    init(format: AVSampleFormat, sampleRate: Int32, layout: AVChannelLayout) throws(FFmpegError) {
        output = try Frame()
        self.format = format
        self.sampleRate = sampleRate
        var source = layout
        try FFmpegError.check(av_channel_layout_copy(&self.layout, &source))
    }

    deinit {
        swr_free(&context)
        av_channel_layout_uninit(&layout)
    }

    /// The returned frame is reused by the next conversion.
    func convert(_ frame: Frame) throws(FFmpegError) -> Frame {
        let input = frame.pointer
        if input.pointee.ch_layout.order == AV_CHANNEL_ORDER_UNSPEC {
            let channels = input.pointee.ch_layout.nb_channels
            av_channel_layout_uninit(&input.pointee.ch_layout)
            av_channel_layout_default(&input.pointee.ch_layout, channels)
        }
        output.unref()
        output.pointer.pointee.format = format.rawValue
        output.pointer.pointee.sample_rate = sampleRate
        try FFmpegError.check(av_channel_layout_copy(&output.pointer.pointee.ch_layout, &layout))
        let current = [input.pointee.sample_rate, input.pointee.format, input.pointee.ch_layout.nb_channels]
        if current != signature {
            swr_free(&context)
            context = swr_alloc()
            guard context != nil else { throw .outOfMemory }
            try FFmpegError.check(swr_config_frame(context, output.pointer, input))
            try FFmpegError.check(swr_init(context))
            signature = current
        }
        try FFmpegError.check(swr_convert_frame(context, output.pointer, input))
        return output
    }
}

/// Collects converted samples until there are enough for one encoder frame.
final class SampleFIFO {
    private let fifo: OpaquePointer
    private let format: AVSampleFormat
    private let sampleRate: Int32
    private var layout: AVChannelLayout
    private let frame: Frame

    init(format: AVSampleFormat, layout: AVChannelLayout, sampleRate: Int32, capacity: Int32) throws(FFmpegError) {
        guard let fifo = av_audio_fifo_alloc(format, layout.nb_channels, capacity) else { throw .outOfMemory }
        self.fifo = fifo
        self.format = format
        self.sampleRate = sampleRate
        self.layout = AVChannelLayout()
        var source = layout
        av_channel_layout_copy(&self.layout, &source)
        frame = try Frame()
    }

    deinit {
        av_audio_fifo_free(fifo)
        av_channel_layout_uninit(&layout)
    }

    var count: Int32 { av_audio_fifo_size(fifo) }

    func write(_ source: Frame, from offset: Int, count: Int) throws(FFmpegError) {
        guard let planes = source.pointer.pointee.extended_data else { throw .invalidData }
        let isPlanar = av_sample_fmt_is_planar(format) != 0
        let channels = Int(layout.nb_channels)
        let stride = Int(av_get_bytes_per_sample(format)) * (isPlanar ? 1 : channels)
        let pointers: [UnsafeMutableRawPointer?] = (0..<(isPlanar ? channels : 1)).map { plane in
            planes[plane].map { UnsafeMutableRawPointer($0 + offset * stride) }
        }
        let written = pointers.withUnsafeBufferPointer { av_audio_fifo_write(fifo, $0.baseAddress, Int32(count)) }
        try FFmpegError.check(written)
    }

    /// The returned frame is reused by the next read.
    func read(_ count: Int32) throws(FFmpegError) -> Frame {
        frame.unref()
        frame.pointer.pointee.nb_samples = count
        frame.pointer.pointee.format = format.rawValue
        frame.pointer.pointee.sample_rate = sampleRate
        try FFmpegError.check(av_channel_layout_copy(&frame.pointer.pointee.ch_layout, &layout))
        try FFmpegError.check(av_frame_get_buffer(frame.pointer, 0))
        guard let planes = frame.pointer.pointee.extended_data else { throw .invalidData }
        let planeCount = av_sample_fmt_is_planar(format) != 0 ? Int(layout.nb_channels) : 1
        let pointers: [UnsafeMutableRawPointer?] = (0..<planeCount).map { planes[$0].map(UnsafeMutableRawPointer.init) }
        let read = pointers.withUnsafeBufferPointer { av_audio_fifo_read(fifo, $0.baseAddress, count) }
        try FFmpegError.check(read)
        return frame
    }
}
