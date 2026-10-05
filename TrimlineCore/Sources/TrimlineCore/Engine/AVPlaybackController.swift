import AVFoundation
import QuartzCore

@MainActor
final class AVPlaybackController: PlaybackController {
    let surface: CALayer?
    private(set) var isPlaying = false
    var onTimeChange: ((TimeInterval) -> Void)?
    var onPlaybackStop: (() -> Void)?

    private struct SeekRequest {
        let time: TimeInterval
        let precise: Bool
    }

    private let player: AVPlayer
    private var timeObserver: Any?
    private var endObserver: (any NSObjectProtocol)?
    private var playRange: ClosedRange<TimeInterval>?
    private var isLooping = false
    private var seekInFlight: SeekRequest?
    private var pendingSeek: SeekRequest?
    // The player parks on the first frame it can show, which can come after a precise target: a file whose
    // first frames reference a missing earlier group (cut AVCHD) starts at 0.08 s. While paused, the
    // requested time is the position, as with the FFmpeg controller.
    private var restingTime: TimeInterval? = 0

    private static let timeUpdateInterval = CMTime(value: 1, timescale: 30)
    // After a stop at the clip end the player sits a frame or so before the boundary;
    // pressing play there should start the clip over rather than end at once.
    private static let restartThreshold: TimeInterval = 0.05

    init(asset: AVAsset, showsVideo: Bool) {
        let item = AVPlayerItem(asset: asset)
        player = AVPlayer(playerItem: item)
        player.actionAtItemEnd = .pause
        if showsVideo {
            let layer = AVPlayerLayer(player: player)
            layer.videoGravity = .resizeAspect
            surface = layer
        } else {
            surface = nil
        }
        observe(item)
    }

    var currentTime: TimeInterval {
        if let target = pendingSeek?.time ?? seekInFlight?.time {
            return target
        }
        if !isPlaying, let restingTime {
            return restingTime
        }
        let seconds = player.currentTime().seconds
        return seconds.isFinite ? seconds : 0
    }

    func play(within range: ClosedRange<TimeInterval>, looping: Bool) {
        guard let item = player.currentItem else { return }
        playRange = range
        isLooping = looping
        item.forwardPlaybackEndTime = CMTime(engineSeconds: range.upperBound)

        let now = currentTime
        if now < range.lowerBound || now >= range.upperBound - Self.restartThreshold {
            seek(to: range.lowerBound, precise: true)
        }
        isPlaying = true
        restingTime = nil
        player.play()
    }

    func pause() {
        isPlaying = false
        restingTime = nil
        player.pause()
    }

    func seek(to time: TimeInterval, precise: Bool) {
        let request = SeekRequest(time: time, precise: precise)
        restingTime = precise && !isPlaying ? time : nil
        guard seekInFlight == nil else {
            pendingSeek = request
            return
        }
        start(request)
    }

    func close() {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        timeObserver = nil
        endObserver = nil
        pendingSeek = nil
        onTimeChange = nil
        onPlaybackStop = nil
        isPlaying = false
        player.pause()
        player.replaceCurrentItem(with: nil)
        (surface as? AVPlayerLayer)?.player = nil
    }

    // MARK: Private

    private func observe(_ item: AVPlayerItem) {
        // Both callbacks are delivered on the main queue, so main actor isolation holds.
        timeObserver = player.addPeriodicTimeObserver(forInterval: Self.timeUpdateInterval, queue: .main) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.reportTime() }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.playbackReachedEnd() }
        }
    }

    private func playbackReachedEnd() {
        guard isPlaying, let playRange else { return }
        if isLooping {
            seek(to: playRange.lowerBound, precise: true)
            player.play()
        } else {
            isPlaying = false
            player.pause()
            reportTime()
            onPlaybackStop?()
        }
    }

    private func start(_ request: SeekRequest) {
        seekInFlight = request
        // Infinite tolerance lets the player land on the nearest key frame, which is what makes scrubbing fast.
        let tolerance = request.precise ? CMTime.zero : CMTime.positiveInfinity
        player.seek(
            to: CMTime(engineSeconds: request.time),
            toleranceBefore: tolerance,
            toleranceAfter: tolerance
        ) { [weak self] _ in
            Task { @MainActor in self?.seekDidFinish() }
        }
    }

    private func seekDidFinish() {
        seekInFlight = nil
        if let next = pendingSeek {
            pendingSeek = nil
            start(next)
        } else {
            reportTime()
        }
    }

    private func reportTime() {
        onTimeChange?(currentTime)
    }
}
