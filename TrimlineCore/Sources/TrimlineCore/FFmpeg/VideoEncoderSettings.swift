import Foundation
import libavcodec
import libavformat
import libavutil

/// How a re-encoded picture is set up: the source's size, rate, colour and roughly its bit rate.
struct VideoEncoderSettings {
    let encoding: Encoding
    let pixelFormat: AVPixelFormat
    let bitRate: Int64
    let keyframeInterval: Int32

    // Bits per pixel per frame: the floor keeps old low-rate sources watchable, the ceiling keeps
    // intermediate codecs (ProRes, MJPEG, DV) from turning into huge files.
    private static let minimumBitsPerPixel = 0.05
    private static let defaultBitsPerPixel = 0.15
    private static let maximumBitsPerPixel = 0.5
    static let fallbackFrameRate = 25.0
    private static let keyframeSeconds = 2.0
    private static let tenBitProfile = "main10"

    init(stream: Demuxer.Stream, in demuxer: Demuxer, encoding: Encoding) {
        self.encoding = encoding
        let parameters = stream.parameters.pointee
        let source = AVPixelFormat(rawValue: parameters.format)
        pixelFormat = Self.pixelFormat(for: source, encoding: encoding)
        let frameRate = stream.frameRate ?? Self.fallbackFrameRate
        let pixelsPerSecond = Double(stream.width * stream.height) * frameRate
        let sourceRate = Self.sourceBitRate(of: stream, in: demuxer)
        let rate = sourceRate.map(Double.init) ?? pixelsPerSecond * Self.defaultBitsPerPixel
        bitRate = Int64(
            rate.clamped(
                to: pixelsPerSecond * Self.minimumBitsPerPixel...pixelsPerSecond * Self.maximumBitsPerPixel))
        keyframeInterval = Int32(max(1, (frameRate * Self.keyframeSeconds).rounded()))
    }

    var isTenBit: Bool { pixelFormat == AV_PIX_FMT_P010LE }

    /// Opens the hardware encoder; a Mac that can't encode 10-bit HEVC gets 8-bit instead.
    func makeEncoder(
        for stream: UnsafeMutablePointer<AVStream>, globalHeader: Bool
    ) throws(FFmpegError) -> (Encoder, AVPixelFormat) {
        do throws(FFmpegError) {
            return (try encoder(for: stream, format: pixelFormat, globalHeader: globalHeader), pixelFormat)
        } catch {
            guard isTenBit else { throw error }
            return (try encoder(for: stream, format: AV_PIX_FMT_NV12, globalHeader: globalHeader), AV_PIX_FMT_NV12)
        }
    }

    /// The head of a smart cut joins a copied stream: the source's profile and depth with no fallback,
    /// parameter sets in front of every key frame, and no reordering, so decode times stay simple.
    func makeHeadEncoder(for stream: UnsafeMutablePointer<AVStream>, profile: Int32) throws(FFmpegError) -> Encoder {
        try encoder(for: stream, format: pixelFormat, globalHeader: false, headProfile: profile)
    }

    // MARK: Private

    private func encoder(
        for stream: UnsafeMutablePointer<AVStream>, format: AVPixelFormat, globalHeader: Bool,
        headProfile: Int32? = nil
    ) throws(FFmpegError) -> Encoder {
        guard let parameters = stream.pointee.codecpar?.pointee else { throw .invalidData }
        // Allowing the software encoder keeps saving possible on Macs whose encoder is busy or missing.
        var options = ["allow_sw": "1"]
        if headProfile == nil, format == AV_PIX_FMT_P010LE {
            options["profile"] = Self.tenBitProfile
        }
        let rate = stream.pointee.avg_frame_rate.num > 0 ? stream.pointee.avg_frame_rate : stream.pointee.r_frame_rate
        return try Encoder(name: encoding.encoder, options: options) { context in
            context.pointee.width = parameters.width
            context.pointee.height = parameters.height
            context.pointee.pix_fmt = format
            context.pointee.time_base = stream.pointee.time_base
            context.pointee.framerate = rate
            context.pointee.sample_aspect_ratio = parameters.sample_aspect_ratio
            context.pointee.bit_rate = bitRate
            context.pointee.gop_size = keyframeInterval
            context.pointee.color_primaries = parameters.color_primaries
            context.pointee.color_trc = parameters.color_trc
            context.pointee.colorspace = parameters.color_space
            context.pointee.color_range = Self.colorRange(of: parameters)
            context.pointee.chroma_sample_location = parameters.chroma_location
            if globalHeader {
                context.pointee.flags |= Int32(AV_CODEC_FLAG_GLOBAL_HEADER)
            }
            // The encoder's own "profile" option is shadowed by the generic one, whose names differ;
            // the number set here is what it falls back to.
            if let headProfile {
                context.pointee.profile = headProfile
                context.pointee.max_b_frames = 0
            }
        }
    }

    static func colorRange(of parameters: AVCodecParameters) -> AVColorRange {
        isFullRangeFormat(AVPixelFormat(rawValue: parameters.format)) ? AVCOL_RANGE_JPEG : parameters.color_range
    }

    static func isFullRangeFormat(_ format: AVPixelFormat) -> Bool {
        [AV_PIX_FMT_YUVJ420P, AV_PIX_FMT_YUVJ422P, AV_PIX_FMT_YUVJ444P].contains(format)
    }

    /// The encoder takes 4:2:0 frames as they are; everything else is converted to NV12 or, for 10-bit HEVC, P010.
    private static func pixelFormat(for source: AVPixelFormat, encoding: Encoding) -> AVPixelFormat {
        let depth = av_pix_fmt_desc_get(source).map { Int($0.pointee.comp.0.depth) } ?? 8
        if encoding == .hevc, depth > 8 { return AV_PIX_FMT_P010LE }
        if [AV_PIX_FMT_YUV420P, AV_PIX_FMT_NV12].contains(source) { return source }
        return source == AV_PIX_FMT_YUVJ420P ? AV_PIX_FMT_YUV420P : AV_PIX_FMT_NV12
    }

    /// The stream's own bit rate, or what the file's rate leaves after the other streams.
    private static func sourceBitRate(of stream: Demuxer.Stream, in demuxer: Demuxer) -> Int64? {
        if stream.bitRate > 0 { return stream.bitRate }
        let videos = demuxer.streams.filter { $0.kind == .video && !$0.isAttachedPicture }
        guard videos.count == 1, demuxer.bitRate > 0 else { return nil }
        let others = demuxer.streams.filter { $0.index != stream.index }.reduce(Int64(0)) { $0 + max(0, $1.bitRate) }
        let remainder = demuxer.bitRate - others
        return remainder > 0 ? remainder : nil
    }
}
