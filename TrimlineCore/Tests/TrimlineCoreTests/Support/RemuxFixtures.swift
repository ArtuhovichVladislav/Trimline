import Foundation
import Testing

// Sources in containers only FFmpeg writes. Video: 25 fps test pattern with a key frame every second.
enum RemuxFixtures {
    static let title = "Trimline Remux"
    static let secondLanguage = "rus"
    static let duration = 6
    /// Chapters every 2 s in the rich Matroska file.
    static let chapterTitles = ["One", "Two", "Three"]

    enum Source: String, CaseIterable, CustomTestStringConvertible {
        case webm, avi, flv, ts, mpg, wmv, ogg, wma, flac, aac, wavpack = "wv", mp4, m4aFromFFmpeg = "m4a"

        var testDescription: String { rawValue }

        var hasVideo: Bool { [.webm, .avi, .flv, .ts, .mpg, .wmv, .mp4].contains(self) }

        var codecs: [String] {
            switch self {
            case .webm: ["-c:v", "libvpx-vp9", "-deadline", "realtime", "-c:a", "libopus"]
            case .avi: ["-c:v", "mpeg4", "-c:a", "libmp3lame"]
            case .flv, .ts, .mp4: ["-c:v", "libx264", "-c:a", "aac"]
            case .mpg: ["-c:v", "mpeg2video", "-c:a", "mp2"]
            case .wmv: ["-c:v", "wmv2", "-c:a", "wmav2"]
            case .ogg: ["-c:a", "libopus"]
            case .wma: ["-c:a", "wmav2"]
            case .flac: ["-c:a", "flac"]
            case .aac: ["-c:a", "aac"]
            case .wavpack: ["-c:a", "wavpack"]
            case .m4aFromFFmpeg: ["-c:a", "aac"]
            }
        }
    }

    static func make(_ source: Source) throws -> URL {
        let fileName = "source-\(source.testDescription).\(source.rawValue)"
        let inputs = source.hasVideo ? videoInputs : []
        return try fixture(
            fileName,
            arguments: inputs + toneInput(frequency: 440) + videoKeyframes(source.hasVideo) + source.codecs
                + ["-metadata", "title=\(title)"]
        )
    }

    /// H.264 + two AAC tracks + SubRip subtitles + chapters + cover art, key frame every 2 s.
    static func richMatroska() throws -> URL {
        let folder = try TestMedia.makeTemporaryFolder()
        let subtitles = folder.appendingPathComponent("subtitles.srt")
        try subtitleText.write(to: subtitles, atomically: true, encoding: .utf8)
        let chapters = folder.appendingPathComponent("chapters.txt")
        try chapterText.write(to: chapters, atomically: true, encoding: .utf8)
        let cover = try fixture(
            "cover.png", arguments: ["-f", "lavfi", "-i", "color=c=red:size=64x64", "-frames:v", "1"])
        return try fixture(
            "rich.mkv",
            arguments: videoInputs + toneInput(frequency: 440) + toneInput(frequency: 880) + [
                "-i", subtitles.path, "-i", chapters.path,
                "-map", "0", "-map", "1", "-map", "2", "-map", "3", "-map_chapters", "4",
                "-c:v", "libx264", "-g", "50", "-c:a", "aac", "-c:s", "srt",
                "-attach", cover.path, "-metadata:s:t", "mimetype=image/png",
                "-metadata", "title=\(title)", "-metadata:s:a:1", "language=\(secondLanguage)",
            ]
        )
    }

    /// RealMedia, which FFmpeg reads but can't write: the clip becomes Matroska.
    /// FFmpeg's own RealMedia writer stamps every audio packet with 0, so the timing is not to be trusted.
    static func realMedia(withVideo: Bool) throws -> URL {
        let tone = toneInput(frequency: 440, sampleRate: 8000)
        let audio = ["-c:a", "real_144", "-ac", "1"]
        return try fixture(
            withVideo ? "video.rm" : "audio.rm",
            arguments: withVideo
                ? realVideoInputs + tone + videoKeyframes(true) + ["-c:v", "rv20"] + audio : tone + audio
        )
    }

    /// A MOV whose display matrix turns the picture by 90°.
    static func rotatedMovie() throws -> URL {
        let plain = try fixture(
            "plain.mov",
            arguments: videoInputs + toneInput(frequency: 440) + videoKeyframes(true) + ["-c:v", "libx264"])
        return try fixture(
            "rotated.mov", arguments: ["-display_rotation:v:0", "90", "-i", plain.path, "-c", "copy"])
    }

    static let location = "+55.7558+037.6173/"

    /// A MOV with the location an iPhone records, in QuickTime metadata keys.
    static func cameraMovie() throws -> URL {
        let plain = try fixture(
            "plain.mov",
            arguments: videoInputs + toneInput(frequency: 440) + videoKeyframes(true) + ["-c:v", "libx264"])
        return try fixture(
            "camera.mov",
            arguments: [
                "-i", plain.path, "-c", "copy", "-movflags", "use_metadata_tags",
                "-metadata", "com.apple.quicktime.location.ISO6709=\(location)",
            ])
    }

    // MARK: Private

    // One encoder thread: the suite runs beside AVAssetWriter fixtures that stall when starved of CPU.
    private static func fixture(_ fileName: String, arguments: [String]) throws -> URL {
        try ExternalFFmpeg.make(fileName, arguments: arguments + ["-threads", "1"])
    }

    private static var videoInputs: [String] {
        ["-f", "lavfi", "-i", "testsrc=duration=\(duration):size=320x180:rate=25"]
    }

    // RealVideo needs sizes in multiples of 16.
    private static var realVideoInputs: [String] {
        ["-f", "lavfi", "-i", "testsrc=duration=\(duration):size=320x176:rate=25"]
    }

    private static func toneInput(frequency: Int, sampleRate: Int = 44_100) -> [String] {
        ["-f", "lavfi", "-i", "sine=frequency=\(frequency):duration=\(duration):sample_rate=\(sampleRate)"]
    }

    private static func videoKeyframes(_ hasVideo: Bool) -> [String] {
        hasVideo ? ["-g", "25", "-pix_fmt", "yuv420p"] : []
    }

    private static let subtitleText = """
        1
        00:00:00,000 --> 00:00:01,500
        First

        2
        00:00:02,200 --> 00:00:03,500
        Second

        3
        00:00:04,500 --> 00:00:05,500
        Third

        """

    private static var chapterText: String {
        let entries = chapterTitles.enumerated().map { index, name in
            "[CHAPTER]\nTIMEBASE=1/1000\nSTART=\(index * 2000)\nEND=\((index + 1) * 2000)\ntitle=\(name)\n"
        }
        return ";FFMETADATA1\n" + entries.joined()
    }
}
