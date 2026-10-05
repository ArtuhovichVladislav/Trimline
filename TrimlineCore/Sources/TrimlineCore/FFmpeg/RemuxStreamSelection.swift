import libavcodec
import libavformat
import libavutil

/// A source stream the clip leaves out because its container can't hold it.
struct SkippedStream: Sendable, Equatable {
    enum Reason: Sendable, Equatable {
        case codecNotSupported
        case tooManyStreams
        case kindNotSupported
    }

    let index: Int
    let codec: String
    let reason: Reason
}

extension RemuxOutput {
    /// Adds every source stream the container can take and tells which ones it couldn't.
    func addStreams(from demuxer: Demuxer, rules: ContainerRules) throws(FFmpegError) -> (
        [RemuxTrack], [SkippedStream]
    ) {
        var tracks: [RemuxTrack] = []
        var skipped: [SkippedStream] = []
        for index in 0..<Int(demuxer.context.pointee.nb_streams) {
            guard let stream = demuxer.stream(index), let parameters = stream.pointee.codecpar else { continue }
            let codec = String(cString: avcodec_get_name(parameters.pointee.codec_id))
            let role = Self.role(of: stream)
            if let reason = Self.copyRefusal(
                of: stream, role: role, rules: rules, taken: tracks.map(\.role), format: format)
            {
                skipped.append(SkippedStream(index: index, codec: codec, reason: reason))
                stream.pointee.discard = AVDISCARD_ALL
                continue
            }
            guard let role else { continue }
            let becomesAttachment = role == .picture && rules.attachments
            let outputIndex = becomesAttachment ? try addAttachment(picture: stream) : try addStream(copying: stream)
            tracks.append(
                RemuxTrack(
                    inputIndex: index, outputIndex: outputIndex, role: becomesAttachment ? .attachment : role,
                    inputTimeBase: stream.pointee.time_base, outputTimeBase: stream.pointee.time_base
                ))
        }
        return (tracks, skipped)
    }

    // MARK: Private

    private static let pictureCodecs: Set<UInt32> = [AV_CODEC_ID_MJPEG.rawValue, AV_CODEC_ID_PNG.rawValue]
    private static let compliance = Int32(FF_COMPLIANCE_NORMAL)

    static func role(of stream: UnsafeMutablePointer<AVStream>) -> RemuxTrack.Role? {
        guard let parameters = stream.pointee.codecpar, parameters.pointee.codec_id != AV_CODEC_ID_NONE else {
            return nil
        }
        let isPicture = stream.pointee.disposition & AV_DISPOSITION_ATTACHED_PIC != 0
        switch parameters.pointee.codec_type {
        case AVMEDIA_TYPE_VIDEO: return isPicture ? .picture : .video
        case AVMEDIA_TYPE_AUDIO: return .audio
        case AVMEDIA_TYPE_SUBTITLE: return .subtitle
        case AVMEDIA_TYPE_ATTACHMENT: return .attachment
        default: return nil
        }
    }

    private static let pngSignatureLength = 8
    private static let pngHeaderEnd = 24

    /// Reads the size from the PNG header when probing couldn't; JPEG covers are decoded and have it.
    private static func fillPictureSize(_ stream: UnsafeMutablePointer<AVStream>) -> Bool {
        guard let parameters = stream.pointee.codecpar else { return false }
        if parameters.pointee.width > 0, parameters.pointee.height > 0 { return true }
        let picture = stream.pointee.attached_pic
        guard parameters.pointee.codec_id == AV_CODEC_ID_PNG, let data = picture.data,
            Int(picture.size) >= pngHeaderEnd
        else { return false }
        let bytes = UnsafeBufferPointer(start: data, count: pngHeaderEnd)
        let field = { (offset: Int) in bytes[offset..<offset + 4].reduce(Int32(0)) { $0 << 8 | Int32($1) } }
        // The IHDR chunk follows the signature: length and type, then width and height.
        parameters.pointee.width = field(pngSignatureLength + 8)
        parameters.pointee.height = field(pngSignatureLength + 12)
        return parameters.pointee.width > 0 && parameters.pointee.height > 0
    }

    /// Why the container can't take a copy of the stream, if it can't.
    static func copyRefusal(
        of stream: UnsafeMutablePointer<AVStream>, role: RemuxTrack.Role?, rules: ContainerRules,
        taken: [RemuxTrack.Role], format: UnsafePointer<AVOutputFormat>?
    ) -> SkippedStream.Reason? {
        let codecID = stream.pointee.codecpar?.pointee.codec_id ?? AV_CODEC_ID_NONE
        if let reason = refusal(of: stream, role: role, rules: rules, taken: taken, format: format) {
            return reason
        }
        return rules.refusedCodecs.contains(String(cString: avcodec_get_name(codecID))) ? .codecNotSupported : nil
    }

    /// Whether the muxer can store the codec; it may still turn down a particular stream.
    static func holds(_ codecID: AVCodecID, rules: ContainerRules, format: UnsafePointer<AVOutputFormat>?) -> Bool {
        if rules.refusedCodecs.contains(String(cString: avcodec_get_name(codecID))) { return false }
        // 0 means the muxer has no way to store the codec; a negative answer means it doesn't know.
        return avformat_query_codec(format, codecID, compliance) != 0
    }

    private static func refusal(
        of stream: UnsafeMutablePointer<AVStream>, role: RemuxTrack.Role?, rules: ContainerRules,
        taken: [RemuxTrack.Role], format: UnsafePointer<AVOutputFormat>?
    ) -> SkippedStream.Reason? {
        guard let role, let codecID = stream.pointee.codecpar?.pointee.codec_id else { return .kindNotSupported }
        switch role {
        case .video:
            guard rules.maxVideo > 0 else { return .kindNotSupported }
            if taken.count(where: { $0 == .video }) >= rules.maxVideo { return .tooManyStreams }
        case .audio:
            guard rules.maxAudio > 0 else { return .kindNotSupported }
            if taken.count(where: { $0 == .audio }) >= rules.maxAudio { return .tooManyStreams }
        case .subtitle:
            guard rules.subtitles else { return .kindNotSupported }
        case .picture:
            guard rules.attachedPictures || rules.attachments else { return .kindNotSupported }
            guard Self.pictureCodecs.contains(codecID.rawValue) else { return .codecNotSupported }
            // Muxers refuse a picture without a size, and the build has no PNG decoder to find it.
            return rules.attachments || Self.fillPictureSize(stream) ? nil : .codecNotSupported
        case .attachment:
            guard rules.attachments else { return .kindNotSupported }
            return av_dict_get(stream.pointee.metadata, "filename", nil, 0) == nil ? .codecNotSupported : nil
        }
        return avformat_query_codec(format, codecID, compliance) == 0 ? .codecNotSupported : nil
    }
}
