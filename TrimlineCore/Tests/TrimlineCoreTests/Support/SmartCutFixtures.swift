import AVFoundation
import Foundation
import Testing

@testable import TrimlineCore

// Long-GOP sources for smart cuts: the red ramp of TranscodeFixtures (frame n has red 8n mod 256), 6 s at
// 25 fps with B-frames and key frames every 2.4 s only (0, 2.4, 4.8), so a cut lands mid-GOP.
enum SmartCutFixtures {
    static let frameRate = 25.0
    static let duration = 6
    static let keyframeInterval = 60

    enum Source: String, CaseIterable, CustomTestStringConvertible {
        case matroskaH264, mp4H264, movH264, tsH264, matroskaHEVC, mp4HEVC, tsHEVC
        case matroskaHEVCOpenGOP, mp4HEVCOpenGOP, matroskaHEVC10, matroskaH264TenBit

        var testDescription: String { rawValue }

        var fileExtension: String {
            switch self {
            case .matroskaH264, .matroskaHEVC, .matroskaHEVCOpenGOP, .matroskaHEVC10, .matroskaH264TenBit: "mkv"
            case .mp4H264, .mp4HEVC, .mp4HEVCOpenGOP: "mp4"
            case .movH264: "mov"
            case .tsH264, .tsHEVC: "ts"
            }
        }

        var codec: String {
            switch self {
            case .matroskaH264, .mp4H264, .movH264, .tsH264, .matroskaH264TenBit: "h264"
            default: "hevc"
            }
        }

        var isQuickTime: Bool { ["mp4", "mov"].contains(fileExtension) }

        fileprivate var arguments: [String] {
            let gop = SmartCutFixtures.keyframeInterval
            let x264 = ["-c:v", "libx264", "-x264-params", "keyint=\(gop):min-keyint=\(gop):scenecut=0"]
            let x265Base = "log-level=error:keyint=\(gop):min-keyint=\(gop):scenecut=0"
            let closedHEVC = ["-c:v", "libx265", "-x265-params", x265Base + ":open-gop=0"]
            let openHEVC = ["-c:v", "libx265", "-x265-params", x265Base + ":open-gop=1"]
            let tag = isQuickTime && codec == "hevc" ? ["-tag:v", "hvc1"] : []
            let audio = ["-c:a", "aac"]
            switch self {
            case .matroskaH264, .mp4H264, .movH264, .tsH264:
                return x264 + ["-pix_fmt", "yuv420p"] + audio
            case .matroskaH264TenBit:
                return x264 + ["-pix_fmt", "yuv420p10le"] + audio
            case .matroskaHEVC, .mp4HEVC, .tsHEVC:
                return closedHEVC + ["-pix_fmt", "yuv420p"] + tag + audio
            case .matroskaHEVC10:
                return closedHEVC + ["-pix_fmt", "yuv420p10le"] + audio
            case .matroskaHEVCOpenGOP, .mp4HEVCOpenGOP:
                return openHEVC + ["-pix_fmt", "yuv420p"] + tag + audio
            }
        }
    }

    static func make(_ source: Source) throws -> URL {
        try ExternalFFmpeg.make(
            "smartcut-\(source.rawValue).\(source.fileExtension)",
            arguments: [
                "-f", "lavfi", "-i",
                "nullsrc=s=320x180:r=25:d=\(duration),geq=r='mod(N*8,256)':g=128:b=64",
                "-f", "lavfi", "-i", "sine=frequency=440:duration=\(duration)",
                "-map", "0", "-map", "1", "-threads", "1",
            ] + source.arguments)
    }

    /// The average red of every frame, in presentation order, as the installed ffmpeg decodes it.
    static func reds(of url: URL) throws -> [Double] {
        let pixels = try ExternalFFmpeg.output([
            "-i", url.path, "-map", "0:v:0", "-fps_mode", "passthrough", "-vf", "scale=4:4", "-f", "rawvideo",
            "-pix_fmt", "rgb24", "-",
        ])
        let frameSize = 4 * 4 * 3
        return stride(from: 0, to: pixels.count - frameSize + 1, by: frameSize).map { start in
            stride(from: start, to: start + frameSize, by: 3).reduce(0) { $0 + Double(pixels[$1]) } / 16
        }
    }

    /// What ffmpeg reports while decoding the whole file: nothing for a clean stream.
    static func decodingErrors(of url: URL) throws -> String {
        guard let ffmpeg = ExternalMP3.encoder else { throw TestMediaError.writerFailed }
        let process = Process()
        process.executableURL = ffmpeg
        process.arguments = ["-hide_banner", "-v", "error", "-i", url.path, "-f", "null", "-"]
        let pipe = Pipe()
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    /// The average red of every frame AVFoundation decodes, and the error that stopped it, if any.
    static func avFoundationReds(of url: URL) async throws -> (reds: [Double], error: (any Error)?) {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw TestMediaError.writerFailed
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 4,
                kCVPixelBufferHeightKey as String: 4,
            ])
        reader.add(output)
        reader.startReading()
        var reds: [Double] = []
        while let sample = output.copyNextSampleBuffer() {
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) else { continue }
            let row = CVPixelBufferGetBytesPerRow(buffer)
            let width = CVPixelBufferGetWidth(buffer)
            let height = CVPixelBufferGetHeight(buffer)
            var sum = 0.0
            for y in 0..<height {
                for x in 0..<width {
                    sum += Double(base[y * row + x * 4 + 2])
                }
            }
            reds.append(sum / Double(width * height))
        }
        return (reds, reader.status == .failed ? reader.error : nil)
    }

    /// The video packets of a file, in decode order, read with the app's own demuxer.
    static func videoPackets(of url: URL) throws -> [(data: Data, isKeyframe: Bool)] {
        let demuxer = try Demuxer(url: url)
        guard let video = demuxer.streams.first(where: { $0.kind == .video }) else { return [] }
        let packet = try Packet()
        var packets: [(Data, Bool)] = []
        while try demuxer.read(into: packet) {
            guard packet.streamIndex == video.index, let data = packet.pointer.pointee.data else { continue }
            packets.append((Data(bytes: data, count: packet.size), packet.isKeyframe))
        }
        return packets
    }
}
