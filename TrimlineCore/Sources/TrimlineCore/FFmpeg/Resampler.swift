import libavutil
import libswresample

/// Converts decoded audio of any layout and sample format to interleaved Float32.
final class Resampler {
    let outputSampleRate: Int
    let outputChannels: Int
    private var context: OpaquePointer?
    private var inputSignature: (rate: Int32, format: Int32, channels: Int32)?

    init(outputSampleRate: Int, outputChannels: Int) {
        self.outputSampleRate = outputSampleRate
        self.outputChannels = outputChannels
    }

    deinit {
        swr_free(&context)
    }

    /// Appends the converted samples of `frame` to `output` (interleaved, `outputChannels` per sample).
    func convert(_ frame: Frame, appendingTo output: inout [Float]) throws(FFmpegError) {
        try configure(for: frame)
        let capacity = Int(swr_get_out_samples(context, Int32(frame.sampleCount)))
        guard capacity > 0 else { return }
        guard let planes = frame.pointer.pointee.extended_data else { throw .invalidData }
        var converted = [Float](repeating: 0, count: capacity * outputChannels)
        let count = converted.withUnsafeMutableBytes { buffer -> Int32 in
            var destination = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self)
            return planes.withMemoryRebound(to: UnsafePointer<UInt8>?.self, capacity: outputChannels) { input in
                swr_convert(context, &destination, Int32(capacity), input, Int32(frame.sampleCount))
            }
        }
        try FFmpegError.check(count)
        output.append(contentsOf: converted.prefix(Int(count) * outputChannels))
    }

    private func configure(for frame: Frame) throws(FFmpegError) {
        let source = frame.pointer.pointee
        let signature = (source.sample_rate, source.format, source.ch_layout.nb_channels)
        if let inputSignature, inputSignature == signature { return }
        swr_free(&context)
        var outputLayout = AVChannelLayout()
        av_channel_layout_default(&outputLayout, Int32(outputChannels))
        var inputLayout = source.ch_layout
        try FFmpegError.check(
            swr_alloc_set_opts2(
                &context, &outputLayout, AV_SAMPLE_FMT_FLT, Int32(outputSampleRate),
                &inputLayout, AVSampleFormat(rawValue: source.format), source.sample_rate, 0, nil))
        try FFmpegError.check(swr_init(context))
        inputSignature = signature
    }
}
