import CoreGraphics
import Foundation
import QuartzCore

@testable import TrimlineCore

final class FakeEngine: MediaEngine {
    let info: MediaInfo
    let keyframes: [TimeInterval]
    let player: FakePlayback

    init(info: MediaInfo, keyframes: [TimeInterval] = [], player: FakePlayback) {
        self.info = info
        self.keyframes = keyframes
        self.player = player
    }

    // MKV by default: a container where fast saving can only start on a key frame.
    @MainActor static func video(
        url: URL = URL(fileURLWithPath: "/tmp/movie.mkv"),
        duration: TimeInterval = 10,
        frameRate: Double = 25,
        keyframes: [TimeInterval] = [0, 2, 4, 6, 8],
        hasAudio: Bool = true
    ) -> FakeEngine {
        let info = MediaInfo(
            url: url, kind: .video, duration: duration, fileSize: 10_000_000,
            displaySize: CGSize(width: 320, height: 180), frameRate: frameRate, estimatedBitRate: 1_000_000,
            hasAudio: hasAudio, audioBitRate: hasAudio ? 128_000 : 0
        )
        return FakeEngine(info: info, keyframes: keyframes, player: FakePlayback())
    }

    @MainActor static func audio(url: URL = URL(fileURLWithPath: "/tmp/song.m4a"), duration: TimeInterval = 10)
        -> FakeEngine
    {
        let info = MediaInfo(
            url: url, kind: .audio, duration: duration, fileSize: 1_000_000,
            displaySize: nil, frameRate: nil, estimatedBitRate: 128_000
        )
        return FakeEngine(info: info, player: FakePlayback())
    }

    @MainActor func makePlayback() -> any PlaybackController {
        player
    }

    func thumbnails(count: Int, height: Int, in range: ClosedRange<TimeInterval>) -> AsyncStream<Thumbnail> {
        AsyncStream { $0.finish() }
    }

    func peaks(buckets: Int) -> AsyncStream<PeakChunk> {
        AsyncStream { $0.finish() }
    }

    func keyframe(atOrBefore time: TimeInterval) async -> TimeInterval {
        guard info.kind == .video else { return time }
        return keyframes.last { $0 <= time } ?? 0
    }

    func frameImage(at time: TimeInterval) async -> CGImage? {
        guard info.kind == .video else { return nil }
        return FakeEngine.solidImage(width: 32, height: 18)
    }

    static func solidImage(width: Int, height: Int) -> CGImage? {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        context?.setFillColor(red: 1, green: 0.5, blue: 0, alpha: 1)
        context?.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context?.makeImage()
    }
}

@MainActor
final class FakePlayback: PlaybackController {
    struct Play: Equatable {
        let range: ClosedRange<TimeInterval>
        let looping: Bool
    }

    struct Seek: Equatable {
        let time: TimeInterval
        let precise: Bool
    }

    private(set) var plays: [Play] = []
    private(set) var seeks: [Seek] = []
    private(set) var isClosed = false

    var surface: CALayer? { nil }
    private(set) var currentTime: TimeInterval = 0
    private(set) var isPlaying = false
    var onTimeChange: ((TimeInterval) -> Void)?
    var onPlaybackStop: (() -> Void)?

    func play(within range: ClosedRange<TimeInterval>, looping: Bool) {
        plays.append(Play(range: range, looping: looping))
        isPlaying = true
    }

    func pause() {
        isPlaying = false
    }

    func seek(to time: TimeInterval, precise: Bool) {
        seeks.append(Seek(time: time, precise: precise))
        currentTime = time
    }

    func close() {
        isClosed = true
        isPlaying = false
    }
}

// Model work finishes in tasks hopping through the main actor, so tests poll for the outcome.
@MainActor
func waitUntil(
    timeout: Duration = .seconds(5),
    _ condition: @MainActor () -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        guard ContinuousClock.now < deadline else { return false }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return true
}
