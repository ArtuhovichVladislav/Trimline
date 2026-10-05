import Foundation
import Testing

// Files for the FFmpeg engine, all made by the locally installed ffmpeg (see ExternalFFmpeg).
enum FFmpegFixtures {
    struct Movie: Sendable, CustomTestStringConvertible {
        let fileName: String
        let codec: [String]

        var testDescription: String { fileName }

        func make() throws -> URL {
            try ExternalFFmpeg.testMovie(fileName, codec: codec)
        }
    }

    static let h264MKV = Movie(
        fileName: "engine-h264.mkv", codec: ["-c:v", "libx264", "-sc_threshold", "0", "-c:a", "aac"])
    static let vp9MKV = Movie(fileName: "vp9.mkv", codec: ["-c:v", "libvpx-vp9", "-c:a", "libopus"])
    static let vp8WebM = Movie(fileName: "engine-vp8.webm", codec: ["-c:v", "libvpx", "-c:a", "vorbis"] + nativeVorbis)
    static let av1WebM = Movie(fileName: "engine-av1.webm", codec: ["-c:v", "libsvtav1", "-c:a", "libopus"])
    static let mpeg4AVI = Movie(fileName: "engine-mpeg4.avi", codec: ["-c:v", "mpeg4", "-c:a", "libmp3lame"])
    static let flv = Movie(fileName: "engine-sorenson.flv", codec: ["-c:v", "flv", "-c:a", "libmp3lame"])
    static let wmv = Movie(fileName: "engine-wmv2.wmv", codec: ["-c:v", "wmv2", "-c:a", "wmav2"])
    static let mpegTS = Movie(
        fileName: "engine-h264.ts", codec: ["-c:v", "libx264", "-sc_threshold", "0", "-c:a", "aac"])

    static let movies = [h264MKV, vp9MKV, vp8WebM, mpeg4AVI, flv, wmv, mpegTS]

    static let oggVorbis = AudioFile(fileName: "engine-tone.ogg", codec: ["-c:a", "vorbis"] + nativeVorbis)
    static let opus = AudioFile(fileName: "engine-tone.opus", codec: ["-c:a", "libopus"])
    static let wma = AudioFile(fileName: "engine-tone.wma", codec: ["-c:a", "wmav2"])

    static let audioFiles = [oggVorbis, opus, wma]

    struct AudioFile: Sendable, CustomTestStringConvertible {
        let fileName: String
        let codec: [String]

        var testDescription: String { fileName }

        func make() throws -> URL {
            try ExternalFFmpeg.make(
                fileName, arguments: ["-f", "lavfi", "-i", "sine=frequency=440:duration=\(toneSeconds)"] + codec)
        }
    }

    static let toneSeconds = 4

    static func rotatedMKV() throws -> URL {
        try ExternalFFmpeg.make(
            "engine-rotated.mkv",
            arguments: [
                "-noautorotate", "-display_rotation:v", "90",
                "-f", "lavfi", "-i", "testsrc=duration=2:size=320x180:rate=25",
                "-c:v", "libx264",
            ]
        )
    }

    /// Written to a pipe, so the muxer can't go back and add cues: seeking has no index to use.
    static func matroskaWithoutCues() throws -> URL {
        let url = folder.appendingPathComponent("no-cues.mkv")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        guard let ffmpeg = ExternalMP3.encoder else { throw TestMediaError.writerFailed }
        let partial = folder.appendingPathComponent("partial-\(UUID().uuidString).mkv")
        FileManager.default.createFile(atPath: partial.path, contents: nil)
        let output = try FileHandle(forWritingTo: partial)
        defer { try? output.close() }
        let process = Process()
        process.executableURL = ffmpeg
        process.arguments = [
            "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "testsrc=duration=4:size=320x180:rate=25",
            "-f", "lavfi", "-i", "sine=frequency=440:duration=4",
            "-g", "25", "-c:v", "libx264", "-sc_threshold", "0", "-c:a", "aac", "-f", "matroska", "pipe:1",
        ]
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw TestMediaError.writerFailed }
        try? FileManager.default.moveItem(at: partial, to: url)
        try? FileManager.default.removeItem(at: partial)
        return url
    }

    /// H.264 and AAC in Matroska with the picture's first key frame at 1 s and the sound from 0, as from
    /// cameras that start recording sound first. Key frame every second.
    static func lateVideoMKV() throws -> URL {
        try ExternalFFmpeg.make(
            "late-video.mkv",
            arguments: ["-itsoffset", "1", "-f", "lavfi", "-i", "testsrc=duration=4:size=320x180:rate=25"]
                + ["-f", "lavfi", "-i", "sine=frequency=440:duration=5"] + offsetCodecs)
    }

    /// The sound starts 2 s after the picture, later than playback feeds sound ahead of the clock.
    static func lateAudioMKV() throws -> URL {
        try ExternalFFmpeg.make(
            "late-audio.mkv",
            arguments: ["-f", "lavfi", "-i", "testsrc=duration=5:size=320x180:rate=25"]
                + ["-itsoffset", "2", "-f", "lavfi", "-i", "sine=frequency=440:duration=3"] + offsetCodecs)
    }

    /// The first 60% of an H.264 Matroska file, as left by an interrupted download.
    static func truncatedMKV() throws -> URL {
        let url = folder.appendingPathComponent("truncated.mkv")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let whole = try Data(contentsOf: try h264MKV.make())
        let partial = folder.appendingPathComponent("partial-\(UUID().uuidString).mkv")
        try whole.prefix(whole.count * 6 / 10).write(to: partial)
        try? FileManager.default.moveItem(at: partial, to: url)
        try? FileManager.default.removeItem(at: partial)
        return url
    }

    /// FFV1 is a lossless archive codec our FFmpeg build has no decoder for.
    static func unsupportedVideo() throws -> URL {
        try ExternalFFmpeg.testMovie("engine-ffv1.mkv", codec: ["-c:v", "ffv1", "-c:a", "libopus"])
    }

    static func unsupportedAudio() throws -> URL {
        try ExternalFFmpeg.make(
            "engine-nellymoser.flv",
            arguments: ["-f", "lavfi", "-i", "sine=frequency=440:duration=2", "-ar", "22050", "-c:a", "nellymoser"]
        )
    }

    static func subtitlesOnly() throws -> URL {
        let subtitles = folder.appendingPathComponent("only.srt")
        try "1\n00:00:00,000 --> 00:00:01,000\nHello\n".write(to: subtitles, atomically: true, encoding: .utf8)
        return try ExternalFFmpeg.make("engine-subtitles.mkv", arguments: ["-i", subtitles.path, "-c:s", "srt"])
    }

    static func hasEncoder(_ name: String) -> Bool {
        encoderList.contains(" \(name) ")
    }

    // MARK: Private

    // The built-in Vorbis encoder is experimental and stereo only; Homebrew's ffmpeg has no libvorbis.
    private static let nativeVorbis = ["-strict", "-2", "-ac", "2"]
    // 4:2:0 so the player passes the picture to VideoToolbox, as with camera files.
    private static let offsetCodecs = ["-g", "25", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac"]

    private static let encoderList: String = {
        guard let ffmpeg = ExternalMP3.encoder else { return "" }
        let process = Process()
        let pipe = Pipe()
        process.executableURL = ffmpeg
        process.arguments = ["-hide_banner", "-encoders"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }()

    private static let folder: URL = {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "TrimlineFFmpegEngine-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }()
}
