import AVFoundation
import QuartzCore

/// Plays files opened by FFmpeg: a pipeline actor reads and decodes, this class only feeds the
/// renderers and drives their shared clock.
@MainActor
final class FFmpegPlaybackController: PlaybackController {
    let surface: CALayer?
    private(set) var isPlaying = false
    var onTimeChange: ((TimeInterval) -> Void)?
    var onPlaybackStop: (() -> Void)?

    private struct SeekRequest {
        let time: TimeInterval
        let precise: Bool
    }

    private enum Phase {
        case opening
        case ready
        case failed
        case closed
    }

    private static let timeUpdateInterval = CMTime(value: 1, timescale: 30)
    // After a stop at the clip end the clock sits at the boundary; play there starts the clip over.
    private static let restartThreshold: TimeInterval = 0.05
    private static let feedPollInterval: Duration = .milliseconds(20)
    // A flush can drop a frame that is enqueued but not yet drawn, so while scrubbing each frame
    // gets this long on screen before the next seek starts.
    private static let scrubFrameHold: Duration = .milliseconds(30)

    private let pipeline: PlaybackPipeline
    private let synchronizer = AVSampleBufferRenderSynchronizer()
    private let surfaceLayer: PlaybackSurfaceLayer?
    private var phase = Phase.opening
    private var renderers: [PlaybackTrack: any AVQueuedSampleBufferRendering] = [:]
    private var lookahead: [PlaybackTrack: TimeInterval] = [:]
    private var openTask: Task<Void, Never>?
    private var seekTask: Task<Void, Never>?
    private var feeders: [Task<Void, Never>] = []
    private let clockGate = ClockGate()
    private var unprimedTracks: Set<PlaybackTrack> = []
    private var seekInFlight: SeekRequest?
    private var pendingSeek: SeekRequest?
    private var playRange: ClosedRange<TimeInterval>?
    private var isLooping = false
    private var timeObserver: Any?
    private var boundaryObserver: Any?

    init(url: URL, info: MediaInfo) {
        let showsVideo = info.kind == .video
        surfaceLayer = showsVideo ? PlaybackSurfaceLayer() : nil
        surface = surfaceLayer
        pipeline = PlaybackPipeline(url: url, includesVideo: showsVideo)
        // Feeding is paced by our own lookahead, which can be shorter than what the renderers
        // consider enough to start; waiting for them would stall playback.
        synchronizer.delaysRateChangeUntilHasSufficientMediaData = false
        observeTime()
        openTask = Task { [weak self, pipeline] in
            let layout = await pipeline.open()
            self?.pipelineDidOpen(layout)
        }
    }

    // A safety net for a controller dropped without `close()`: its feeders hold it weakly and end once
    // the gate they may wait at is closed.
    deinit {
        Task { @MainActor [clockGate, pipeline] in
            clockGate.close()
            await pipeline.close()
        }
    }

    var currentTime: TimeInterval {
        if let target = pendingSeek?.time ?? seekInFlight?.time {
            return target
        }
        let seconds = synchronizer.currentTime().seconds
        return seconds.isFinite ? seconds : 0
    }

    func play(within range: ClosedRange<TimeInterval>, looping: Bool) {
        guard phase == .opening || phase == .ready else { return }
        playRange = range
        isLooping = looping
        observeRangeEnd(range.upperBound)

        let now = currentTime
        if now < range.lowerBound || now >= range.upperBound - Self.restartThreshold {
            seek(to: range.lowerBound, precise: true)
        }
        isPlaying = true
        if phase == .ready, seekInFlight == nil {
            startClock()
        }
    }

    func pause() {
        isPlaying = false
        synchronizer.rate = 0
        removeRangeEndObserver()
    }

    func seek(to time: TimeInterval, precise: Bool) {
        let request = SeekRequest(time: time, precise: precise)
        guard phase == .ready, seekInFlight == nil else {
            if phase != .closed {
                pendingSeek = request
            }
            return
        }
        start(request)
    }

    func close() {
        guard phase != .closed else { return }
        phase = .closed
        openTask?.cancel()
        seekTask?.cancel()
        stopFeeding()
        removeRangeEndObserver()
        if let timeObserver {
            synchronizer.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        synchronizer.rate = 0
        for renderer in renderers.values {
            synchronizer.removeRenderer(renderer, at: synchronizer.currentTime())
        }
        renderers.removeAll()
        seekInFlight = nil
        pendingSeek = nil
        isPlaying = false
        onTimeChange = nil
        onPlaybackStop = nil
        Task { [pipeline] in await pipeline.close() }
    }

    // MARK: Opening and seeking

    private func pipelineDidOpen(_ layout: PlaybackLayout?) {
        guard phase == .opening else { return }
        guard let layout else {
            phase = .failed
            pendingSeek = nil
            if isPlaying {
                isPlaying = false
                onPlaybackStop?()
            }
            return
        }
        for track in layout.tracks {
            let renderer: any AVQueuedSampleBufferRendering
            switch track {
            case .video:
                guard let surfaceLayer else { continue }
                renderer = surfaceLayer.displayLayer.sampleBufferRenderer
            case .audio:
                renderer = AVSampleBufferAudioRenderer()
            }
            renderers[track] = renderer
            synchronizer.addRenderer(renderer)
        }
        lookahead = layout.lookahead
        surfaceLayer?.quarterTurns = layout.quarterTurns
        phase = .ready
        let request = pendingSeek ?? SeekRequest(time: 0, precise: true)
        pendingSeek = nil
        start(request)
    }

    private func start(_ request: SeekRequest) {
        seekInFlight = request
        stopFeeding()
        synchronizer.rate = 0
        seekTask = Task { [weak self, pipeline] in
            let result = await pipeline.seek(to: request.time, precise: request.precise)
            self?.pipelineDidSeek(result)
        }
    }

    private func pipelineDidSeek(_ result: PlaybackPipeline.SeekResult) {
        guard phase == .ready, seekInFlight != nil else { return }
        synchronizer.setRate(0, time: CMTime(engineSeconds: result.time))
        unprimedTracks = Set(renderers.keys)
        feeders = renderers.map { track, renderer in
            feed(track, into: renderer, generation: result.generation)
        }
        if unprimedTracks.isEmpty {
            finishSeek()
        }
    }

    private func trackDidPrime(_ track: PlaybackTrack) {
        guard seekInFlight != nil, unprimedTracks.remove(track) != nil, unprimedTracks.isEmpty else { return }
        guard pendingSeek != nil else {
            finishSeek()
            return
        }
        seekTask = Task { [weak self] in
            try? await Task.sleep(for: Self.scrubFrameHold)
            guard !Task.isCancelled else { return }
            self?.finishSeek()
        }
    }

    private func finishSeek() {
        guard phase == .ready else { return }
        seekInFlight = nil
        if let next = pendingSeek {
            pendingSeek = nil
            start(next)
            return
        }
        if isPlaying {
            startClock()
        }
        reportTime()
    }

    // MARK: Feeding

    private enum Room {
        case ready
        case afterClockStarts
        case later
    }

    /// Feeds one renderer until its track ends or a newer seek begins. The task holds the controller weakly and
    /// waits for the clock at the gate, so it never keeps a controller alive on its own.
    private func feed(_ track: PlaybackTrack, into renderer: any AVQueuedSampleBufferRendering, generation: Int)
        -> Task<Void, Never>
    {
        let lookahead = lookahead[track] ?? 0
        return Task { [weak self, pipeline, clockGate] in
            while !Task.isCancelled, let sample = await pipeline.nextSample(for: track, generation: generation) {
                let time = sample.presentationTime
                while true {
                    guard !Task.isCancelled, let room = self?.room(for: time, of: track, in: renderer, ahead: lookahead)
                    else { return }
                    if room == .ready { break }
                    if room == .afterClockStarts {
                        await clockGate.wait()
                    } else {
                        try? await Task.sleep(for: Self.feedPollInterval)
                    }
                }
                renderer.enqueue(sample.buffer)
                self?.trackDidPrime(track)
            }
            if !Task.isCancelled {
                self?.trackDidPrime(track)
            }
        }
    }

    private func room(
        for time: TimeInterval, of track: PlaybackTrack, in renderer: any AVQueuedSampleBufferRendering,
        ahead lookahead: TimeInterval
    ) -> Room {
        let isTooEarly = time - synchronizer.currentTime().seconds > lookahead
        if renderer.isReadyForMoreMediaData, !isTooEarly { return .ready }
        guard isTooEarly, synchronizer.rate == 0 else { return .later }
        // Nothing of this track shows before the clock moves on, so it is as ready as it gets. A track that
        // starts later than the seek target (picture stamped a second after the sound) would otherwise hold
        // the seek, and with it the clock, forever.
        trackDidPrime(track)
        return synchronizer.rate == 0 ? .afterClockStarts : .later
    }

    private func stopFeeding() {
        for feeder in feeders {
            feeder.cancel()
        }
        feeders.removeAll()
        clockGate.open()
        for renderer in renderers.values {
            renderer.flush()
        }
    }

    private func startClock() {
        synchronizer.rate = 1
        clockGate.open()
    }

    // MARK: Time observation

    private func observeTime() {
        // Both observers are delivered on the main queue, so main actor isolation holds.
        timeObserver = synchronizer.addPeriodicTimeObserver(forInterval: Self.timeUpdateInterval, queue: .main) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.clockDidTick() }
        }
    }

    private func observeRangeEnd(_ end: TimeInterval) {
        removeRangeEndObserver()
        let times = [NSValue(time: CMTime(engineSeconds: end))]
        boundaryObserver = synchronizer.addBoundaryTimeObserver(forTimes: times, queue: .main) { [weak self] in
            MainActor.assumeIsolated { self?.playbackReachedEnd() }
        }
    }

    private func removeRangeEndObserver() {
        if let boundaryObserver {
            synchronizer.removeTimeObserver(boundaryObserver)
        }
        boundaryObserver = nil
    }

    private func clockDidTick() {
        guard seekInFlight == nil, pendingSeek == nil else { return }
        // The boundary observer can miss the end when the clock jumps past it.
        if isPlaying, let playRange, currentTime >= playRange.upperBound {
            playbackReachedEnd()
        } else {
            reportTime()
        }
    }

    private func playbackReachedEnd() {
        guard isPlaying, seekInFlight == nil, let playRange else { return }
        if isLooping {
            seek(to: playRange.lowerBound, precise: true)
            return
        }
        isPlaying = false
        synchronizer.setRate(0, time: CMTime(engineSeconds: playRange.upperBound))
        removeRangeEndObserver()
        reportTime()
        onPlaybackStop?()
    }

    private func reportTime() {
        onTimeChange?(currentTime)
    }
}

/// Where feeders wait for a stopped clock. Kept apart from the controller, so a waiting feeder holds only
/// the gate; once closed, the gate never makes anyone wait again.
@MainActor
private final class ClockGate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var isClosed = false

    func wait() async {
        guard !isClosed else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        let resumed = waiters
        waiters.removeAll()
        for waiter in resumed {
            waiter.resume()
        }
    }

    func close() {
        isClosed = true
        open()
    }
}
