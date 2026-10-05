import libavcodec
import libavformat
import libavutil

final class Encoder {
    let context: UnsafeMutablePointer<AVCodecContext>

    /// `configure` fills in the stream parameters before the encoder opens with `options`.
    init(
        name: String, options: [String: String] = [:], configure: (UnsafeMutablePointer<AVCodecContext>) -> Void
    ) throws(FFmpegError) {
        guard let codec = avcodec_find_encoder_by_name(name) else { throw .encoderNotFound }
        guard let context = avcodec_alloc_context3(codec) else { throw .outOfMemory }
        self.context = context
        configure(context)
        var dictionary: OpaquePointer?
        defer { av_dict_free(&dictionary) }
        for (key, value) in options {
            try FFmpegError.check(av_dict_set(&dictionary, key, value, 0))
        }
        try FFmpegError.check(avcodec_open2(context, codec, &dictionary))
    }

    deinit {
        var closing: UnsafeMutablePointer<AVCodecContext>? = context
        avcodec_free_context(&closing)
    }

    var timeBase: AVRational { context.pointee.time_base }

    /// Sends a frame, or `nil` to drain the encoder at the end of the stream.
    func send(_ frame: Frame?) throws(FFmpegError) {
        try FFmpegError.check(avcodec_send_frame(context, frame?.pointer))
    }

    /// Returns `false` when the encoder needs more input or is fully drained.
    func receive(into packet: Packet) throws(FFmpegError) -> Bool {
        let result = FFmpegError(code: avcodec_receive_packet(context, packet.pointer))
        if result.isTryAgain || result.isEndOfFile { return false }
        try FFmpegError.check(result.code)
        return true
    }
}

/// Where re-encoded pictures go: a stream of their own, or the head of a smart cut.
protocol EncodedVideoOutput: AnyObject {
    var encoder: Encoder { get }
    /// Sends a frame, or `nil` to drain the encoder.
    func send(_ frame: Frame?) throws(FFmpegError)
}

/// An encoder feeding one stream of the clip.
final class EncodedStream: EncodedVideoOutput {
    let encoder: Encoder
    let outputIndex: Int
    private let output: RemuxOutput
    private let packet: Packet

    init(encoder: Encoder, source: UnsafeMutablePointer<AVStream>, output: RemuxOutput) throws(FFmpegError) {
        self.encoder = encoder
        self.output = output
        outputIndex = try output.addStream(encodedBy: encoder.context, source: source)
        packet = try Packet()
    }

    func send(_ frame: Frame?) throws(FFmpegError) {
        try encoder.send(frame)
        try writePackets()
    }

    private func writePackets() throws(FFmpegError) {
        let timeBase = output.timeBase(ofStream: outputIndex)
        while try encoder.receive(into: packet) {
            packet.pointer.pointee.stream_index = Int32(outputIndex)
            av_packet_rescale_ts(packet.pointer, encoder.timeBase, timeBase)
            try output.write(packet)
        }
    }
}
