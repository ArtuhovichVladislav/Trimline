import Foundation
import Testing

// Sources for re-encoding: frame n is one flat colour with red = 8n (mod 256), so the first frame of a
// clip tells exactly where it starts. 25 fps, key frame every second, 2 s long.
enum TranscodeFixtures {
    static let frameRate = 25.0
    static let redPerFrame = 8.0
    static let duration = 2

    enum Source: String, CaseIterable, CustomTestStringConvertible {
        case matroskaH264, matroskaVP9, webmVP9, aviMPEG4, mp4H264, matroskaHEVC10

        var testDescription: String { rawValue }

        var fileExtension: String {
            switch self {
            case .matroskaH264, .matroskaVP9, .matroskaHEVC10: "mkv"
            case .webmVP9: "webm"
            case .aviMPEG4: "avi"
            case .mp4H264: "mp4"
            }
        }

        var audioTracks: Int { self == .matroskaH264 ? 2 : 1 }

        fileprivate var codecs: [String] {
            switch self {
            case .matroskaH264: ["-c:v", "libx264", "-c:a:0", "aac", "-c:a:1", "libopus"]
            case .matroskaVP9, .webmVP9: ["-c:v", "libvpx-vp9", "-deadline", "realtime", "-c:a", "libopus"]
            case .aviMPEG4: ["-c:v", "mpeg4", "-q:v", "2", "-c:a", "libmp3lame"]
            case .mp4H264: ["-c:v", "libx264", "-c:a", "aac"]
            case .matroskaHEVC10: ["-c:v", "libx265", "-x265-params", "log-level=error", "-c:a", "libopus"]
            }
        }

        fileprivate var pixelFormat: String { self == .matroskaHEVC10 ? "yuv420p10le" : "yuv420p" }
    }

    static func make(_ source: Source) throws -> URL {
        let tones = (0..<source.audioTracks).flatMap { tone(frequency: 440 * ($0 + 1)) }
        let maps = (0...source.audioTracks).flatMap { ["-map", "\($0)"] }
        return try ExternalFFmpeg.make(
            "transcode-\(source.rawValue).\(source.fileExtension)",
            arguments: rampInput + tones + maps + ["-g", "25", "-pix_fmt", source.pixelFormat] + source.codecs
                + ["-threads", "1"])
    }

    /// The average red of the frame shown at `seconds`, read back by the locally installed ffmpeg.
    static func averageRed(of url: URL, at seconds: TimeInterval) throws -> Double {
        let seek = seconds > 0 ? ["-ss", String(seconds)] : []
        let pixels = try ExternalFFmpeg.output(
            seek + ["-i", url.path, "-frames:v", "1", "-vf", "scale=4:4", "-f", "rawvideo", "-pix_fmt", "rgb24", "-"])
        let reds = stride(from: 0, to: pixels.count, by: 3).map { Double(pixels[$0]) }
        guard !reds.isEmpty else { throw TestMediaError.writerFailed }
        return reds.reduce(0, +) / Double(reds.count)
    }

    private static var rampInput: [String] {
        [
            "-f", "lavfi", "-i",
            "nullsrc=s=320x180:r=25:d=\(duration),geq=r='mod(N*\(Int(redPerFrame)),256)':g=128:b=64",
        ]
    }

    private static func tone(frequency: Int) -> [String] {
        ["-f", "lavfi", "-i", "sine=frequency=\(frequency):duration=\(duration)"]
    }
}

extension ExternalFFmpeg {
    /// Runs ffmpeg and returns what it writes to standard output.
    static func output(_ arguments: [String]) throws -> Data {
        guard let ffmpeg = ExternalMP3.encoder else { throw TestMediaError.writerFailed }
        let process = Process()
        process.executableURL = ffmpeg
        process.arguments = ["-hide_banner", "-loglevel", "error"] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw TestMediaError.writerFailed }
        return data
    }
}
