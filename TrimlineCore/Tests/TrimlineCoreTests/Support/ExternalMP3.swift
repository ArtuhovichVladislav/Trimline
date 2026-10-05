import Foundation

// macOS has no MP3 encoder, so MP3 fixtures come from a locally installed ffmpeg when there is one.
enum ExternalMP3 {
    static let title = "Trimline Fixture"
    static let duration: TimeInterval = 10

    private static let candidates = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]

    static var encoder: URL? {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map(URL.init(fileURLWithPath:))
    }

    static func make() throws -> URL {
        guard let encoder else { throw TestMediaError.writerFailed }
        let url = try TestMedia.makeTemporaryFolder().appendingPathComponent("tone.mp3")
        let process = Process()
        process.executableURL = encoder
        process.arguments = [
            "-hide_banner", "-loglevel", "error",
            "-f", "lavfi", "-i", "sine=frequency=440:duration=\(duration)",
            "-c:a", "libmp3lame", "-b:a", "128k",
            "-id3v2_version", "3", "-metadata", "title=\(title)",
            url.path,
        ]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw TestMediaError.writerFailed }
        return url
    }
}
