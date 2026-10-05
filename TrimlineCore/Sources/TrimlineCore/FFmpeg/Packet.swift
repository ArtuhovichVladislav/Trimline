import libavcodec

final class Packet {
    let pointer: UnsafeMutablePointer<AVPacket>

    init() throws(FFmpegError) {
        guard let packet = av_packet_alloc() else { throw .outOfMemory }
        pointer = packet
    }

    deinit {
        var packet: UnsafeMutablePointer<AVPacket>? = pointer
        av_packet_free(&packet)
    }

    var streamIndex: Int { Int(pointer.pointee.stream_index) }
    var pts: Int64 { pointer.pointee.pts }
    var dts: Int64 { pointer.pointee.dts }
    var duration: Int64 { pointer.pointee.duration }
    /// The presentation time, or the decode time when the container leaves it out.
    var time: Int64 { pts != FFmpegTime.noValue ? pts : dts }
    var size: Int { Int(pointer.pointee.size) }
    var isKeyframe: Bool { pointer.pointee.flags & AV_PKT_FLAG_KEY != 0 }

    func unref() {
        av_packet_unref(pointer)
    }
}
