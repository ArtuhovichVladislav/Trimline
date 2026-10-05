import Foundation
import libavcodec
import libavformat
import libavutil

/// What happens to each source stream when a clip is written: copied, re-encoded or left out.
struct TranscodePlan {
    enum Action: Equatable {
        case copy
        case encode(Encoding)
        case skip(SkippedStream.Reason)
    }

    struct Entry {
        let index: Int
        let codec: String
        let role: RemuxTrack.Role
        let action: Action
    }

    let entries: [Entry]

    var encodes: Bool { entries.contains { if case .encode = $0.action { true } else { false } } }

    /// The codec the clip's picture is encoded to, when it is encoded.
    var videoEncoding: Encoding? {
        entries.lazy.compactMap { entry in
            if entry.role == .video, case .encode(let encoding) = entry.action { encoding } else { nil }
        }.first
    }

    var skipped: [SkippedStream] {
        entries.compactMap { entry in
            guard case .skip(let reason) = entry.action else { return nil }
            return SkippedStream(index: entry.index, codec: entry.codec, reason: reason)
        }
    }

    init(demuxer: Demuxer, container: ExportContainer, mode: ExportMode) {
        let format = av_guess_format(container.muxer, nil, nil)
        var entries: [Entry] = []
        for index in 0..<Int(demuxer.context.pointee.nb_streams) {
            guard let stream = demuxer.stream(index), let codecID = stream.pointee.codecpar?.pointee.codec_id else {
                continue
            }
            let role = RemuxOutput.role(of: stream)
            let refusal = RemuxOutput.copyRefusal(
                of: stream, role: role, rules: container.rules, taken: entries.taken, format: format)
            guard let role else { continue }
            let action = Self.action(
                for: codecID, role: role, refusal: refusal, mode: mode, rules: container.rules, format: format)
            let codec = String(cString: avcodec_get_name(codecID))
            entries.append(Entry(index: index, codec: codec, role: role, action: action))
        }
        self.entries = entries
    }

    // MARK: Private

    // Only FFmpeg-based players read RealMedia codecs, even from Matroska, so they never stay as they are.
    private static let realMediaCodecs: Set<UInt32> = Set(
        [
            AV_CODEC_ID_RV10, AV_CODEC_ID_RV20, AV_CODEC_ID_RV30, AV_CODEC_ID_RV40,
            AV_CODEC_ID_COOK, AV_CODEC_ID_RA_144, AV_CODEC_ID_RA_288, AV_CODEC_ID_SIPR, AV_CODEC_ID_ATRAC3,
        ].map(\.rawValue))

    private static func action(
        for codecID: AVCodecID, role: RemuxTrack.Role, refusal: SkippedStream.Reason?,
        mode: ExportMode, rules: ContainerRules, format: UnsafePointer<AVOutputFormat>?
    ) -> Action {
        let needsEncoding =
            refusal == .codecNotSupported || realMediaCodecs.contains(codecID.rawValue)
            || (mode == .precise && role == .video)
        switch (role, refusal) {
        case (.video, nil), (.video, .codecNotSupported), (.audio, nil), (.audio, .codecNotSupported):
            guard needsEncoding else { return .copy }
            guard avcodec_find_decoder(codecID) != nil,
                let encoding = encoding(for: codecID, role: role, rules: rules, format: format)
            else { return .skip(.codecNotSupported) }
            return .encode(encoding)
        case (_, .some(let reason)):
            return .skip(reason)
        case (_, nil):
            return .copy
        }
    }

    private static func encoding(
        for codecID: AVCodecID, role: RemuxTrack.Role, rules: ContainerRules, format: UnsafePointer<AVOutputFormat>?
    ) -> Encoding? {
        // Which containers take the new picture codec is ExportContainer's choice, made before the plan.
        guard role == .audio else { return Encoding.video(for: codecID) }
        return Encoding.audio(for: codecID).first { encoding in
            avcodec_find_encoder_by_name(encoding.encoder) != nil
                && RemuxOutput.holds(encoding.codecID, rules: rules, format: format)
        }
    }
}

/// The encoder a re-encoded stream goes through.
struct Encoding: Equatable, Sendable {
    let encoder: String
    let codecID: AVCodecID

    static let h264 = Encoding(encoder: "h264_videotoolbox", codecID: AV_CODEC_ID_H264)
    static let hevc = Encoding(encoder: "hevc_videotoolbox", codecID: AV_CODEC_ID_HEVC)
    static let aac = Encoding(encoder: "aac_at", codecID: AV_CODEC_ID_AAC)
    static let flac = Encoding(encoder: "flac", codecID: AV_CODEC_ID_FLAC)

    var codecName: String { String(cString: avcodec_get_name(codecID)) }

    /// H.264 stays H.264; everything else becomes HEVC, the hardware encoder's other codec.
    static func video(for source: AVCodecID) -> Encoding {
        source == AV_CODEC_ID_H264 ? .h264 : .hevc
    }

    /// Sound that may be lossless (Monkey's Audio, WavPack) stays lossless where the container takes FLAC.
    static func audio(for source: AVCodecID) -> [Encoding] {
        let props = avcodec_descriptor_get(source)?.pointee.props ?? 0
        return props & AV_CODEC_PROP_LOSSLESS != 0 ? [.flac, .aac] : [.aac]
    }
}

extension [TranscodePlan.Entry] {
    fileprivate var taken: [RemuxTrack.Role] {
        compactMap { entry in
            if case .skip = entry.action { nil } else { entry.role }
        }
    }
}
