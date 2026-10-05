import Foundation

// Formats AVFoundation can't write (MKV, WebM, AVI, OGG…) come from a locally installed ffmpeg.
// Tests that need them are skipped when it is missing.
enum ExternalFFmpeg {
    static var isAvailable: Bool { ExternalMP3.encoder != nil }

    /// Runs ffmpeg with `arguments` writing `fileName` into a fresh folder, once per process and name.
    static func make(_ fileName: String, arguments: [String]) throws -> URL {
        guard let ffmpeg = ExternalMP3.encoder else { throw TestMediaError.writerFailed }
        let url = cacheFolder.appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let partial = cacheFolder.appendingPathComponent("partial-\(UUID().uuidString)-\(fileName)")
        let process = Process()
        process.executableURL = ffmpeg
        process.arguments = ["-hide_banner", "-loglevel", "error", "-y"] + arguments + [partial.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw TestMediaError.writerFailed }
        // Parallel tests may race for the same fixture; whoever renames first wins.
        try? FileManager.default.moveItem(at: partial, to: url)
        try? FileManager.default.removeItem(at: partial)
        return url
    }

    /// A test pattern with a tone: `seconds` long, key frame every `keyframeInterval` frames at 25 fps.
    static func testMovie(_ fileName: String, codec: [String], seconds: Int = 4, keyframeInterval: Int = 25) throws
        -> URL
    {
        try make(
            fileName,
            arguments: [
                "-f", "lavfi", "-i", "testsrc=duration=\(seconds):size=320x180:rate=25",
                "-f", "lavfi", "-i", "sine=frequency=440:duration=\(seconds)",
                "-g", "\(keyframeInterval)",
            ] + codec
        )
    }

    private static let cacheFolder: URL = {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "TrimlineFFmpegFixtures-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }()
}
