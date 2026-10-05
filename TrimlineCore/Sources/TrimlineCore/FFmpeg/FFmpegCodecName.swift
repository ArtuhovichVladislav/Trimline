import libavcodec

// Our FFmpeg is built with --enable-small, which drops the codecs' long names, so the names a person
// may recognise in an error message come from here. Mostly codecs the build can't decode.
enum FFmpegCodecName {
    private static let knownNames: [String: String] = [
        "h264": "H.264", "hevc": "HEVC", "vp8": "VP8", "vp9": "VP9", "av1": "AV1", "mpeg4": "MPEG-4",
        "mpeg2video": "MPEG-2", "theora": "Theora", "ffv1": "FFV1", "huffyuv": "HuffYUV", "ffvhuff": "HuffYUV",
        "binkvideo": "Bink", "bink": "Bink", "cinepak": "Cinepak", "indeo3": "Indeo", "indeo4": "Indeo",
        "indeo5": "Indeo", "svq1": "Sorenson Video", "svq3": "Sorenson Video 3", "qtrle": "QuickTime Animation",
        "msvideo1": "Microsoft Video 1", "rv10": "RealVideo 1", "rv20": "RealVideo 2", "vp3": "VP3", "vp7": "VP7",
        "dnxhd": "DNxHD", "cfhd": "CineForm", "hap": "Hap", "utvideo": "Ut Video", "lagarith": "Lagarith",
        "dirac": "Dirac", "jpeg2000": "JPEG 2000", "h261": "H.261", "snow": "Snow", "flashsv": "Flash Screen Video",
        "aac": "AAC", "mp3": "MP3", "ac3": "AC-3", "eac3": "E-AC-3", "dts": "DTS", "truehd": "Dolby TrueHD",
        "mlp": "MLP", "binkaudio_dct": "Bink Audio", "binkaudio_rdft": "Bink Audio", "nellymoser": "Nellymoser",
        "speex": "Speex", "tta": "TTA", "tak": "TAK", "musepack7": "Musepack", "musepack8": "Musepack",
        "shorten": "Shorten", "gsm": "GSM", "g723_1": "G.723.1", "g729": "G.729", "qdm2": "QDesign Music 2",
        "atrac3": "ATRAC3", "atrac3p": "ATRAC3+", "mace3": "MACE", "mace6": "MACE", "aptx": "aptX",
    ]
    private static let families = ["adpcm_": "ADPCM", "pcm_": "PCM"]

    static func displayName(for stream: Demuxer.Stream) -> String {
        guard stream.codecID != AV_CODEC_ID_NONE else {
            return CodecName.fourCharacterCode(stream.parameters.pointee.codec_tag.byteSwapped)
        }
        return displayName(forCodecNamed: stream.codecName)
    }

    static func displayName(forCodecNamed name: String) -> String {
        if let known = knownNames[name] { return known }
        return families.first { name.hasPrefix($0.key) }?.value ?? name
    }
}
