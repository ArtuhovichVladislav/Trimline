import libavcodec
import libavutil

final class Decoder {
    let context: UnsafeMutablePointer<AVCodecContext>

    /// - Parameter threadCount: 0 lets FFmpeg pick one thread per core.
    init(stream: Demuxer.Stream, threadCount: Int32 = 0) throws(FFmpegError) {
        guard let codec = avcodec_find_decoder(stream.codecID) else { throw .decoderNotFound }
        guard let context = avcodec_alloc_context3(codec) else { throw .outOfMemory }
        self.context = context
        try FFmpegError.check(avcodec_parameters_to_context(context, stream.parameters))
        context.pointee.pkt_timebase = stream.timeBase
        context.pointee.thread_count = threadCount
        try FFmpegError.check(avcodec_open2(context, codec, nil))
    }

    deinit {
        var closing: UnsafeMutablePointer<AVCodecContext>? = context
        avcodec_free_context(&closing)
    }

    /// Thumbnails only need key frames; skipping the rest makes long-GOP files fast.
    var decodesKeyframesOnly: Bool {
        get { context.pointee.skip_frame == AVDISCARD_NONKEY }
        set { context.pointee.skip_frame = newValue ? AVDISCARD_NONKEY : AVDISCARD_DEFAULT }
    }

    /// Sends a packet, or `nil` to drain the decoder at the end of the stream. Frames from earlier packets
    /// must have been received first (until `receive` returns `false`): a decoder still holding one
    /// refuses the packet with `FFmpegError.tryAgain`.
    func send(_ packet: Packet?) throws(FFmpegError) {
        try FFmpegError.check(avcodec_send_packet(context, packet?.pointer))
    }

    /// Returns `false` when the decoder needs more input or is fully drained.
    func receive(into frame: Frame) throws(FFmpegError) -> Bool {
        let result = FFmpegError(code: avcodec_receive_frame(context, frame.pointer))
        if result.isTryAgain || result.isEndOfFile { return false }
        try FFmpegError.check(result.code)
        return true
    }

    func flush() {
        avcodec_flush_buffers(context)
    }
}
