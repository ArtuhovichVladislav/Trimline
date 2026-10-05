import CoreGraphics
import CoreMedia
import Foundation
import libavcodec
import libavformat
import libavutil

/// Reads a file for playback on its own actor and hands out ready sample buffers track by track.
/// Every call does its work without suspending, so a seek never interleaves with a half-read sample.
actor PlaybackPipeline {
    struct SeekResult: Sendable {
        let generation: Int
        /// Where the clock should stand: the target, or the key frame a fast seek landed on.
        let time: TimeInterval
    }

    private final class TrackState {
        let streamIndex: Int
        let source: any PlaybackSource
        /// Video can only resume decoding at a key frame after packets are dropped.
        let needsKeyframes: Bool
        var packets: [Packet] = []
        var queuedBytes = 0
        var ready: [CMSampleBuffer] = []
        var isDrained = false
        private var skipsToKeyframe = false

        init(streamIndex: Int, source: any PlaybackSource, needsKeyframes: Bool) {
            self.streamIndex = streamIndex
            self.source = source
            self.needsKeyframes = needsKeyframes
        }

        func reset() {
            packets.removeAll()
            queuedBytes = 0
            ready.removeAll()
            isDrained = false
            skipsToKeyframe = false
        }

        /// Over `limit`, the oldest packets go: whole groups of pictures for video, so decoding picks up
        /// cleanly at the next key frame instead of mid-GOP.
        func queue(_ packet: Packet, limit: Int) {
            if skipsToKeyframe {
                guard packet.isKeyframe else { return }
                skipsToKeyframe = false
            }
            packets.append(packet)
            queuedBytes += packet.size
            while queuedBytes > limit, packets.count > 1 {
                let next = needsKeyframes ? packets.dropFirst().firstIndex(where: \.isKeyframe) : 1
                let dropped = next ?? packets.count
                queuedBytes -= packets[..<dropped].reduce(0) { $0 + $1.size }
                packets.removeFirst(dropped)
                skipsToKeyframe = packets.isEmpty
            }
        }
    }

    // The demuxer interleaves streams, so one track's packets wait while the other is read;
    // a badly interleaved file must not make that wait unbounded.
    private static let maximumQueuedPacketBytes = 32 * 1024 * 1024
    private static let compressedVideoLookahead: TimeInterval = 0.5
    private static let audioLookahead: TimeInterval = 1
    private static let fallbackFrameRate = 25.0
    private static let landingTolerance: TimeInterval = 0.01
    // Cameras often start the sound a frame or two early; reopening the file isn't worth that much.
    private static let soundLeadWorthReopening: TimeInterval = 0.1
    private static let keyframeSearchPacketLimit = 5_000

    private let url: URL
    private let includesVideo: Bool
    private let queue = BlockingWork.queue(for: PlaybackPipeline.self)
    private var demuxer: Demuxer?
    private var tracks: [PlaybackTrack: TrackState] = [:]
    private var videoTiming: StreamTiming?
    private var origin: TimeInterval = 0
    private var lastFrameStart: TimeInterval = .infinity
    private var videoStart: TimeInterval = 0
    private var videoStartsOnKeyframe = false
    private var generation = 0
    private var reachedEndOfFile = false

    init(url: URL, includesVideo: Bool) {
        self.url = url
        self.includesVideo = includesVideo
    }

    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    /// Returns `nil` when the file has nothing this pipeline can play.
    func open() -> PlaybackLayout? {
        guard let demuxer = try? Demuxer(url: url) else { return nil }
        self.demuxer = demuxer
        origin = demuxer.timelineOrigin
        var lookahead: [PlaybackTrack: TimeInterval] = [:]
        var quarterTurns = 0
        if includesVideo, let stream = demuxer.streams.first(where: isPlayableVideo),
            let (source, ahead) = makeVideoSource(stream, in: demuxer)
        {
            tracks[.video] = TrackState(streamIndex: stream.index, source: source, needsKeyframes: true)
            lookahead[.video] = ahead
            quarterTurns = stream.quarterTurns
        }
        if let stream = demuxer.streams.first(where: isPlayableAudio),
            let source = try? AudioSource(stream: stream, timing: timing(of: stream, in: demuxer))
        {
            tracks[.audio] = TrackState(streamIndex: stream.index, source: source, needsKeyframes: false)
            lookahead[.audio] = Self.audioLookahead
        }
        return lookahead.isEmpty ? nil : PlaybackLayout(lookahead: lookahead, quarterTurns: quarterTurns)
    }

    func seek(to time: TimeInterval, precise: Bool) -> SeekResult {
        generation += 1
        let target = max(0, time)
        let landing = position(before: target)
        let start = precise ? target : (landing ?? target)
        // A target past the last frame would hide every frame; the last one stays on screen instead.
        tracks[.video]?.source.restart(at: Self.cmTime(min(start, lastFrameStart)))
        tracks[.audio]?.source.restart(at: Self.cmTime(start))
        return SeekResult(generation: generation, time: start)
    }

    /// Returns `nil` at the end of the track or once a newer seek has made `generation` stale.
    func nextSample(for track: PlaybackTrack, generation: Int) -> PlaybackSample? {
        guard generation == self.generation, let state = tracks[track] else { return nil }
        while state.ready.isEmpty {
            if !state.packets.isEmpty {
                let packet = state.packets.removeFirst()
                state.queuedBytes -= packet.size
                state.source.append(packet, to: &state.ready)
            } else if state.isDrained {
                return nil
            } else if !readPacket() {
                state.source.drain(to: &state.ready)
                state.isDrained = true
            }
        }
        return PlaybackSample(buffer: state.ready.removeFirst())
    }

    func close() {
        generation += 1
        tracks.removeAll()
        demuxer = nil
    }

    // MARK: Private

    private func readPacket() -> Bool {
        guard !reachedEndOfFile, let demuxer, let packet = try? Packet() else { return false }
        // Read errors other than the end of the file are fatal for the rest of it, so both end the tracks.
        guard (try? demuxer.read(into: packet)) == true else {
            reachedEndOfFile = true
            return false
        }
        tracks.values.first { $0.streamIndex == packet.streamIndex }?
            .queue(packet, limit: Self.maximumQueuedPacketBytes)
        return true
    }

    /// Puts the read position before `target` and returns where video decoding will begin.
    private func position(before target: TimeInterval) -> TimeInterval? {
        guard let demuxer else { return nil }
        resetReading()
        guard let video = tracks[.video] else {
            if let audio = tracks[.audio] {
                try? demuxer.seek(streamIndex: audio.streamIndex, to: target + origin)
            }
            return nil
        }
        // A seek on the picture can't land before its first key frame, so sound that starts well before the
        // picture is read from the start of the file.
        let needsEarlierSound = tracks[.audio] != nil && videoStart - target > Self.soundLeadWorthReopening
        if !needsEarlierSound {
            let latestGoodLanding = max(target, videoStart) + Self.landingTolerance
            let landing = demuxer.seek(
                streamIndex: video.streamIndex, before: target + origin, streamStart: videoStart + origin,
                isCancelled: { false }
            ) { () -> TimeInterval? in
                resetReading()
                return firstVideoPacketTime().flatMap { $0 <= latestGoodLanding ? $0 : nil }
            }
            if let landing { return landing }
        }
        resetReading()
        self.demuxer = (try? demuxer.positioned(at: .fileStart, streamIndex: video.streamIndex)) ?? demuxer
        return firstVideoPacketTime()
    }

    private func resetReading() {
        reachedEndOfFile = false
        for track in tracks.values { track.reset() }
    }

    /// Reads until the first video packet the source can start from and returns its time.
    private func firstVideoPacketTime() -> TimeInterval? {
        guard let video = tracks[.video], let videoTiming else { return nil }
        // A stream that never flags key frames must not make a seek read the whole file.
        for _ in 0..<Self.keyframeSearchPacketLimit {
            while videoStartsOnKeyframe, let first = video.packets.first, !first.isKeyframe {
                video.queuedBytes -= video.packets.removeFirst().size
            }
            if let first = video.packets.first {
                return (videoTiming.time(first.pts) ?? videoTiming.time(first.dts))?.seconds
            }
            guard readPacket() else { return nil }
        }
        return nil
    }

    private func makeVideoSource(_ stream: Demuxer.Stream, in demuxer: Demuxer) -> (any PlaybackSource, TimeInterval)? {
        let timing = timing(of: stream, in: demuxer)
        videoTiming = timing
        if let duration = demuxer.duration ?? stream.duration {
            lastFrameStart = max(0, duration - timing.fallbackDuration.seconds)
        }
        videoStart = max(0, (stream.startTime ?? origin) - origin)
        let pixelAspect = av_guess_sample_aspect_ratio(demuxer.context, demuxer.stream(stream.index), nil)
        if let format = PlaybackVideoFormat(stream: stream, pixelAspect: pixelAspect) {
            videoStartsOnKeyframe = true
            return (CompressedVideoSource(format: format, timing: timing), Self.compressedVideoLookahead)
        }
        var width = Double(stream.width)
        if pixelAspect.num > 0, pixelAspect.den > 0 {
            width *= Double(pixelAspect.num) / Double(pixelAspect.den)
        }
        let displaySize = CGSize(width: width, height: Double(stream.height))
        guard let decoded = try? DecodedVideoSource(stream: stream, displaySize: displaySize, timing: timing) else {
            return nil
        }
        return (decoded, decoded.lookahead)
    }

    private func timing(of stream: Demuxer.Stream, in demuxer: Demuxer) -> StreamTiming {
        let guessed = av_guess_frame_rate(demuxer.context, demuxer.stream(stream.index), nil)
        let frameRate = guessed.num > 0 && guessed.den > 0 ? Double(guessed.num) / Double(guessed.den) : nil
        return StreamTiming(
            timeBase: stream.timeBase,
            origin: Self.cmTime(origin),
            fallbackDuration: Self.cmTime(1 / (frameRate ?? stream.frameRate ?? Self.fallbackFrameRate)))
    }

    private func isPlayableVideo(_ stream: Demuxer.Stream) -> Bool {
        stream.kind == .video && !stream.isAttachedPicture && avcodec_find_decoder(stream.codecID) != nil
    }

    private func isPlayableAudio(_ stream: Demuxer.Stream) -> Bool {
        stream.kind == .audio && avcodec_find_decoder(stream.codecID) != nil
    }

    private static func cmTime(_ seconds: TimeInterval) -> CMTime {
        CMTime(engineSeconds: seconds)
    }
}
