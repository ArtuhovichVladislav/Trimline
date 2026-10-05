import Foundation
import libavcodec
import libavformat

// The sound alone is copied into the format its codec usually lives in, so the clip opens as an ordinary
// audio file; a codec without one goes to Matroska audio (decision 0010).
extension ExportContainer {
    /// The first sound track's codec decides; the other tracks stay where the format holds several
    /// (M4A, MKA). Reads the file's header.
    static func forSound(of source: URL) -> ExportContainer {
        guard let demuxer = try? Demuxer(url: source) else { return sound(in: .mka) }
        let codecs = demuxer.streams.filter { $0.kind == .audio }.map(\.codecID)
        guard let first = codecs.first,
            let format = SoundFormat.candidates(for: first).first(where: { $0.holds(first) })
        else { return sound(in: .mka) }
        // A track M4A can't hold would be lost or re-encoded; Matroska keeps them all as they are.
        if format == .m4a, !codecs.dropFirst().allSatisfy(format.holds) {
            return sound(in: .mka)
        }
        return sound(in: format)
    }

    static let multitrackSoundMuxers: Set<String> = [SoundFormat.m4a.muxer, matroska]

    private static func sound(in format: SoundFormat) -> ExportContainer {
        ExportContainer(
            fileExtension: format.fileExtension, changesContainer: false, muxer: format.muxer, content: .soundOnly)
    }
}

private struct SoundFormat: Equatable {
    let fileExtension: String
    let muxer: String

    static let m4a = SoundFormat(fileExtension: "m4a", muxer: "ipod")
    static let mka = SoundFormat(fileExtension: ExportContainer.audioFallbackExtension, muxer: ExportContainer.matroska)
    private static let wav = SoundFormat(fileExtension: "wav", muxer: "wav")
    private static let aiff = SoundFormat(fileExtension: "aiff", muxer: "aiff")
    private static let caf = SoundFormat(fileExtension: "caf", muxer: "caf")

    // WAV takes little-endian PCM only; big-endian PCM from QuickTime files fits AIFF, the rest CAF.
    static func candidates(for codec: AVCodecID) -> [SoundFormat] {
        switch codec {
        case AV_CODEC_ID_AAC, AV_CODEC_ID_ALAC: [.m4a]
        case AV_CODEC_ID_MP3: [SoundFormat(fileExtension: "mp3", muxer: "mp3")]
        case AV_CODEC_ID_OPUS: [SoundFormat(fileExtension: "opus", muxer: "ogg")]
        case AV_CODEC_ID_VORBIS: [SoundFormat(fileExtension: "ogg", muxer: "ogg")]
        case AV_CODEC_ID_FLAC: [SoundFormat(fileExtension: "flac", muxer: "flac")]
        case AV_CODEC_ID_AC3: [SoundFormat(fileExtension: "ac3", muxer: "ac3")]
        case AV_CODEC_ID_EAC3: [SoundFormat(fileExtension: "eac3", muxer: "eac3")]
        default: String(cString: avcodec_get_name(codec)).hasPrefix("pcm_") ? [.wav, .aiff, .caf] : []
        }
    }

    func holds(_ codec: AVCodecID) -> Bool {
        guard RemuxOutput.isAvailable(muxer: muxer) else { return false }
        return RemuxOutput.holds(codec, rules: .singleAudio, format: av_guess_format(muxer, nil, nil))
    }
}

extension ContainerRules {
    /// Leaves out the tracks the chosen content drops. Players read only the first track of the single-track
    /// audio formats, even of Ogg, which could take more.
    func keeping(_ content: ExportContent, muxer: String) -> ContainerRules {
        var rules = self
        switch content {
        case .videoAndSound:
            break
        case .videoOnly:
            rules.maxAudio = 0
        case .soundOnly:
            rules.maxVideo = 0
            rules.subtitles = false
            if !ExportContainer.multitrackSoundMuxers.contains(muxer) {
                rules.maxAudio = min(rules.maxAudio, 1)
            }
        }
        return rules
    }
}
