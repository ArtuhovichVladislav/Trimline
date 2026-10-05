import Foundation
import libavcodec
import libavformat
import libavutil

/// One opened input file. Not thread-safe: each actor that reads a file opens its own demuxer.
final class Demuxer {
    struct Stream {
        enum Kind {
            case video
            case audio
            case subtitle
            case other
        }

        let index: Int
        let kind: Kind
        let codecID: AVCodecID
        let codecName: String
        let timeBase: AVRational
        let startTime: TimeInterval?
        let duration: TimeInterval?
        let width: Int
        let height: Int
        let frameRate: Double?
        let sampleRate: Int
        let channelCount: Int
        let bitRate: Int64
        /// Clockwise rotation in degrees from the display matrix.
        let rotation: Double
        /// Cover art in audio files is a one-frame "video" stream.
        let isAttachedPicture: Bool
        /// Owned by the demuxer's format context: valid only while the `Demuxer` that described the stream
        /// is alive, so a stream is never kept apart from its demuxer.
        let parameters: UnsafeMutablePointer<AVCodecParameters>
    }

    // Capped probing (docs/spec.md), so opening never scans the whole file looking for streams.
    private static let probeSize: Int64 = 5 * 1024 * 1024
    private static let analyzeDuration: Int64 = 5 * FFmpegTime.microsecondsPerSecond

    let url: URL
    let context: UnsafeMutablePointer<AVFormatContext>
    let streams: [Stream]

    init(url: URL) throws(FFmpegError) {
        self.url = url
        FFmpegLog.quietOnce
        guard var context = avformat_alloc_context() else { throw .outOfMemory }
        context.pointee.probesize = Self.probeSize
        context.pointee.max_analyze_duration = Self.analyzeDuration
        var opened: UnsafeMutablePointer<AVFormatContext>? = context
        // avformat_open_input frees the context itself when it fails.
        try FFmpegError.check(avformat_open_input(&opened, url.path, nil, nil))
        guard let opened else { throw .invalidData }
        context = opened
        do {
            try FFmpegError.check(avformat_find_stream_info(context, nil))
        } catch {
            var closing: UnsafeMutablePointer<AVFormatContext>? = context
            avformat_close_input(&closing)
            throw error
        }
        self.context = context
        self.streams = (0..<Int(context.pointee.nb_streams)).compactMap { index in
            context.pointee.streams[index].flatMap { Self.describe($0, index: index) }
        }
    }

    deinit {
        var closing: UnsafeMutablePointer<AVFormatContext>? = context
        avformat_close_input(&closing)
    }

    var formatName: String {
        context.pointee.iformat.map { String(cString: $0.pointee.name) } ?? ""
    }

    var duration: TimeInterval? {
        let value = context.pointee.duration
        guard value != FFmpegTime.noValue, value > 0 else { return nil }
        return Double(value) / Double(FFmpegTime.microsecondsPerSecond)
    }

    var bitRate: Int64 { context.pointee.bit_rate }

    func stream(_ index: Int) -> UnsafeMutablePointer<AVStream>? {
        guard index >= 0, index < Int(context.pointee.nb_streams) else { return nil }
        return context.pointee.streams[index]
    }

    /// Fills `packet` with the next packet of any stream. Returns `false` at the end of the file.
    func read(into packet: Packet) throws(FFmpegError) -> Bool {
        packet.unref()
        let result = FFmpegError(code: av_read_frame(context, packet.pointer))
        if result.isEndOfFile { return false }
        try FFmpegError.check(result.code)
        return true
    }

    /// Seeks so that the next packet of `streamIndex` is the key frame at or before `time`.
    func seek(streamIndex: Int, to time: TimeInterval) throws(FFmpegError) {
        guard let stream = stream(streamIndex) else { throw .invalidData }
        let timestamp = FFmpegTime.timestamp(time, in: stream.pointee.time_base)
        try FFmpegError.check(av_seek_frame(context, Int32(streamIndex), timestamp, AVSEEK_FLAG_BACKWARD))
    }

    private static func describe(_ stream: UnsafeMutablePointer<AVStream>, index: Int) -> Stream? {
        guard let parameters = stream.pointee.codecpar else { return nil }
        let codec = parameters.pointee
        let timeBase = stream.pointee.time_base
        let rate = stream.pointee.avg_frame_rate
        return Stream(
            index: index,
            kind: kind(of: codec.codec_type),
            codecID: codec.codec_id,
            codecName: String(cString: avcodec_get_name(codec.codec_id)),
            timeBase: timeBase,
            startTime: FFmpegTime.seconds(stream.pointee.start_time, in: timeBase),
            duration: FFmpegTime.seconds(stream.pointee.duration, in: timeBase),
            width: Int(codec.width),
            height: Int(codec.height),
            frameRate: rate.den > 0 && rate.num > 0 ? Double(rate.num) / Double(rate.den) : nil,
            sampleRate: Int(codec.sample_rate),
            channelCount: Int(codec.ch_layout.nb_channels),
            bitRate: codec.bit_rate,
            rotation: rotation(of: codec),
            isAttachedPicture: stream.pointee.disposition & AV_DISPOSITION_ATTACHED_PIC != 0,
            parameters: parameters
        )
    }

    private static func kind(of type: AVMediaType) -> Stream.Kind {
        switch type {
        case AVMEDIA_TYPE_VIDEO: .video
        case AVMEDIA_TYPE_AUDIO: .audio
        case AVMEDIA_TYPE_SUBTITLE: .subtitle
        default: .other
        }
    }

    private static func rotation(of codec: AVCodecParameters) -> Double {
        guard
            let sideData = av_packet_side_data_get(
                codec.coded_side_data, codec.nb_coded_side_data, AV_PKT_DATA_DISPLAYMATRIX),
            let data = sideData.pointee.data
        else { return 0 }
        let angle = data.withMemoryRebound(to: Int32.self, capacity: 9) { av_display_rotation_get($0) }
        // av_display_rotation_get is counter-clockwise; players think clockwise.
        return angle.isFinite ? -angle : 0
    }
}

extension Demuxer.Stream {
    private static let degreesPerQuarterTurn = 90.0
    private static let quarterTurnsPerTurn = 4

    /// The rotation as clockwise quarter turns, 0...3.
    var quarterTurns: Int {
        let turns = Int((rotation / Self.degreesPerQuarterTurn).rounded()) % Self.quarterTurnsPerTurn
        return (turns + Self.quarterTurnsPerTurn) % Self.quarterTurnsPerTurn
    }
}
