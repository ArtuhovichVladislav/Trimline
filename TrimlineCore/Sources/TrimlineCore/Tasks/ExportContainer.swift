import Foundation

/// The container a clip is written to: the source's own, or Matroska when the source's can't be written;
/// for the sound alone, the format of its codec.
public struct ExportContainer: Sendable, Equatable {
    public let fileExtension: String
    /// The clip gets a different container than the source, which the save panel warns about.
    public let changesContainer: Bool
    let muxer: String
    var content = ExportContent.videoAndSound

    public static func forSource(_ source: URL) -> ExportContainer {
        let sourceExtension = source.pathExtension.lowercased()
        if let muxer = muxers[sourceExtension].flatMap(availableMuxer) {
            return ExportContainer(fileExtension: source.pathExtension, changesContainer: false, muxer: muxer)
        }
        let fallback = audioOnlyExtensions.contains(sourceExtension) ? audioFallbackExtension : videoFallbackExtension
        return ExportContainer(fileExtension: fallback, changesContainer: true, muxer: matroska)
    }

    /// The container for a clip saved in `mode`. When the picture is re-encoded to a codec the source's
    /// container can't hold (HEVC in WebM or AVI), the clip becomes Matroska. Reads the file's header.
    public static func forSource(_ source: URL, mode: ExportMode) -> ExportContainer {
        let container = forSource(source)
        guard let codec = Transcoder.videoEncoding(of: source, container: container, mode: mode),
            !(encodedVideoMuxers[codec]?.contains(container.muxer) ?? false)
        else { return container }
        return ExportContainer(fileExtension: videoFallbackExtension, changesContainer: true, muxer: matroska)
    }

    /// The container for a clip of `content`; the sound alone gets a format of its own.
    public static func forSource(_ source: URL, mode: ExportMode, content: ExportContent) -> ExportContainer {
        guard content.keepsVideo else { return forSound(of: source) }
        var container = forSource(source, mode: mode)
        container.content = content
        return container
    }

    /// QuickTime-family containers hide the frames before the cut with an edit list.
    var hasEditList: Bool { Self.editListMuxers.contains(muxer) }

    var rules: ContainerRules { (Self.rules[muxer] ?? .singleAudio).keeping(content, muxer: muxer) }

    var muxerOptions: [String: String] {
        Self.m2tsExtensions.contains(fileExtension.lowercased()) ? ["mpegts_m2ts_mode": "1"] : [:]
    }

    // MARK: Private

    // A muxer left out of the FFmpeg build is replaced by a close relative that reads the same, if there is one.
    static func availableMuxer(_ name: String) -> String? {
        if RemuxOutput.isAvailable(muxer: name) { return name }
        return substitutes[name].flatMap { RemuxOutput.isAvailable(muxer: $0) ? $0 : nil }
    }

    private static let substitutes = ["3gp": "mp4"]

    static let matroska = "matroska"
    private static let videoFallbackExtension = "mkv"
    static let audioFallbackExtension = "mka"
    private static let audioOnlyExtensions: Set<String> = ["ape", "ra"]
    // AVCHD camera files use 192-byte packets with a timecode in front of each.
    private static let m2tsExtensions: Set<String> = ["mts", "m2ts"]
    private static let editListMuxers: Set<String> = ["mov", "mp4", "ipod", "3gp"]

    private static let muxers: [String: String] = [
        "mov": "mov", "qt": "mov",
        "mp4": "mp4", "f4v": "mp4",
        "m4v": "ipod", "m4a": "ipod", "m4b": "ipod",
        "3gp": "3gp", "3gpp": "3gp", "3g2": "3gp",
        "mkv": matroska, "mka": matroska, "mk3d": matroska,
        "webm": "webm",
        "avi": "avi",
        "wmv": "asf", "wma": "asf", "asf": "asf",
        "flv": "flv",
        "ts": "mpegts", "mts": "mpegts", "m2ts": "mpegts", "m2t": "mpegts",
        "mpg": "mpeg", "mpeg": "mpeg", "vob": "vob",
        "ogg": "ogg", "ogv": "ogg", "oga": "ogg", "opus": "ogg", "spx": "ogg",
        "mp3": "mp3",
        "aac": "adts",
        "wav": "wav", "wave": "wav",
        "w64": "w64",
        "aif": "aiff", "aiff": "aiff", "aifc": "aiff",
        "caf": "caf",
        "flac": "flac",
        "ac3": "ac3",
        "eac3": "eac3", "ec3": "eac3",
        "dts": "dts",
        "wv": "wv",
        "amr": "amr",
        "dv": "dv",
    ]

    // Where players expect the hardware encoder's output; AVI, WebM, ASF and the like technically take HEVC
    // or have no way to store it at all.
    private static let encodedVideoMuxers: [String: Set<String>] = [
        "h264": ["mov", "mp4", "ipod", "3gp", matroska, "mpegts", "flv"],
        "hevc": ["mov", "mp4", "ipod", matroska, "mpegts"],
    ]

    // libavformat's Matroska muxer lists these RealMedia codecs but refuses to write them.
    private static let matroskaRefusedCodecs: Set<String> = [
        "atrac3", "cook", "ra_288", "sipr", "rv10", "rv20", "rv30",
    ]

    private static let rules: [String: ContainerRules] = [
        "mov": .quickTime, "mp4": .quickTime, "ipod": .quickTime,
        "3gp": ContainerRules(maxVideo: .max, maxAudio: .max, subtitles: true),
        matroska: ContainerRules(
            maxVideo: .max, maxAudio: .max, subtitles: true, attachedPictures: true, attachments: true,
            refusedCodecs: matroskaRefusedCodecs),
        "webm": ContainerRules(maxVideo: .max, maxAudio: .max, subtitles: true),
        "avi": ContainerRules(maxVideo: .max, maxAudio: .max, subtitles: true),
        "asf": ContainerRules(maxVideo: .max, maxAudio: .max),
        "flv": ContainerRules(maxVideo: 1, maxAudio: 1),
        "mpegts": ContainerRules(maxVideo: .max, maxAudio: .max, subtitles: true),
        "mpeg": ContainerRules(maxVideo: .max, maxAudio: .max, subtitles: true),
        "vob": ContainerRules(maxVideo: .max, maxAudio: .max, subtitles: true),
        "ogg": ContainerRules(maxVideo: .max, maxAudio: .max),
        "dv": ContainerRules(maxVideo: 1, maxAudio: 2),
        "mp3": .singleAudioWithPictures, "flac": .singleAudioWithPictures,
    ]
}

/// Which streams a container takes; the muxer's own codec check comes on top.
struct ContainerRules: Sendable, Equatable {
    var maxVideo = 0
    var maxAudio = 1
    var subtitles = false
    var attachedPictures = false
    var attachments = false
    var refusedCodecs: Set<String> = []

    static let singleAudio = ContainerRules()
    static let singleAudioWithPictures = ContainerRules(attachedPictures: true)
    static let quickTime = ContainerRules(maxVideo: .max, maxAudio: .max, subtitles: true, attachedPictures: true)
}
