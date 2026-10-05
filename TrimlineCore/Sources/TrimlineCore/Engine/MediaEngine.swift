import CoreGraphics
import Foundation
import QuartzCore

public protocol MediaEngine: Sendable {
    var info: MediaInfo { get }

    @MainActor func makePlayback() -> any PlaybackController

    func thumbnails(count: Int, height: Int, in range: ClosedRange<TimeInterval>) -> AsyncStream<Thumbnail>

    func peaks(buckets: Int) -> AsyncStream<PeakChunk>

    // Fast export copies packets, so a clip can only start on a key frame. Returns `time` for audio.
    func keyframe(atOrBefore time: TimeInterval) async -> TimeInterval

    // The frame on screen at `time`, not the nearest key frame, at full size as the player shows it:
    // rotated, with square pixels, in SDR. `nil` for audio, when decoding fails or when cancelled.
    func frameImage(at time: TimeInterval) async -> CGImage?
}

// Main actor because AVPlayer is UI-actor isolated; none of the calls block.
@MainActor
public protocol PlaybackController: AnyObject {
    var surface: CALayer? { get }

    var currentTime: TimeInterval { get }

    var isPlaying: Bool { get }

    var onTimeChange: ((TimeInterval) -> Void)? { get set }

    var onPlaybackStop: (() -> Void)? { get set }

    func play(within range: ClosedRange<TimeInterval>, looping: Bool)

    func pause()

    // Only one seek in flight; a newer request replaces the pending one.
    func seek(to time: TimeInterval, precise: Bool)

    func close()
}

public struct Thumbnail: Sendable {
    public let index: Int
    public let time: TimeInterval
    public let image: CGImage

    public init(index: Int, time: TimeInterval, image: CGImage) {
        self.index = index
        self.time = time
        self.image = image
    }
}

public struct Peak: Sendable, Equatable, Codable {
    public var min: Float
    public var max: Float

    public init(min: Float, max: Float) {
        self.min = min
        self.max = max
    }
}

public struct PeakChunk: Sendable, Equatable {
    public let firstBucket: Int
    public let peaks: [Peak]

    public init(firstBucket: Int, peaks: [Peak]) {
        self.firstBucket = firstBucket
        self.peaks = peaks
    }
}
