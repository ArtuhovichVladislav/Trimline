import CoreGraphics
import Foundation
import libavcodec
import libavformat
import libavutil

// Finds the frame on screen at a time: decodes from the key frame before it and keeps the last
// frame that starts at or before the time. Each request opens the file anew; decoding dominates.
actor FFmpegFrameGrabber {
    private enum Scan {
        case found(Frame)
        // The seek put the first decodable frame after the target: MPEG-TS bisects by decode
        // timestamps, and an open GOP's leading frames can't be decoded from its key frame.
        case landedLate
        case failed
    }

    private let url: URL
    private let video: FFmpegProbe.VideoStream
    private let timelineOrigin: TimeInterval
    private let queue = BlockingWork.queue(for: FFmpegFrameGrabber.self)

    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    // The player's clock counts in 90 kHz ticks (CMTime.engineTimescale), so it shows a frame that
    // starts less than a tick after the time it was asked for.
    private static let clockTick: TimeInterval = 1.0 / 90_000
    // Far more than any real GOP; a stream without usable timestamps must not be read to its end.
    private static let maximumPacketsPerScan = 5_000

    init(url: URL, video: FFmpegProbe.VideoStream, timelineOrigin: TimeInterval) {
        self.url = url
        self.video = video
        self.timelineOrigin = timelineOrigin
    }

    func image(at time: TimeInterval) -> CGImage? {
        guard let frame = decodeFrame(at: timelineOrigin + time), !Task.isCancelled else { return nil }
        let aspect = video.displaySize.flatMap { $0.height > 0 ? Double($0.width / $0.height) : nil }
        return FrameStillRenderer.image(of: frame, quarterTurns: video.quarterTurns, displayAspectRatio: aspect)
    }

    // MARK: Private

    private func decodeFrame(at target: TimeInterval) -> Frame? {
        guard let demuxer = try? Demuxer(url: url),
            let stream = demuxer.streams.first(where: { $0.index == video.index }),
            let reader = try? FrameReader(demuxer: demuxer, stream: stream)
        else { return nil }
        demuxer.discardAllStreams(except: stream.index)
        let streamStart = stream.startTime ?? timelineOrigin

        let landing = demuxer.seek(
            streamIndex: stream.index, before: target, streamStart: streamStart, isCancelled: { Task.isCancelled }
        ) { () -> Scan? in
            let scan = reader.scan(upTo: target + Self.clockTick, acceptsLateStart: false)
            if case .landedLate = scan { return nil }
            return scan
        }
        if let landing {
            if case .found(let frame) = landing { return frame }
            return nil
        }
        // Some demuxers can't reach the start by timestamp. A time before the first frame shows that frame.
        guard !Task.isCancelled, let rewound = try? demuxer.positioned(at: .fileStart, streamIndex: stream.index),
            let fromStart = try? FrameReader(demuxer: rewound, stream: stream)
        else { return nil }
        if case .found(let frame) = fromStart.scan(upTo: target + Self.clockTick, acceptsLateStart: true) {
            return frame
        }
        return nil
    }

    private final class FrameReader {
        private let demuxer: Demuxer
        private let stream: Demuxer.Stream
        private let decoder: Decoder
        private let packet: Packet
        private let decoded: Frame

        init(demuxer: Demuxer, stream: Demuxer.Stream) throws(FFmpegError) {
            self.demuxer = demuxer
            self.stream = stream
            decoder = try Decoder(stream: stream)
            packet = try Packet()
            decoded = try Frame()
        }

        func scan(upTo limit: TimeInterval, acceptsLateStart: Bool) -> Scan {
            decoder.flush()
            var kept: Frame?
            var hasKeyframe = false
            var packets = 0
            while packets < FFmpegFrameGrabber.maximumPacketsPerScan, !Task.isCancelled {
                guard (try? demuxer.read(into: packet)) == true else { break }
                guard packet.streamIndex == stream.index else { continue }
                packets += 1
                // Frames before the first key frame after a seek decode to garbage, if at all.
                if !hasKeyframe {
                    guard packet.isKeyframe else { continue }
                    hasKeyframe = true
                    if !acceptsLateStart, let time = seconds(of: packet), time > limit { return .landedLate }
                }
                guard (try? decoder.sendTolerantly(packet)) != nil else { return .failed }
                if let result = receiveFrames(upTo: limit, keeping: &kept, acceptsLateStart: acceptsLateStart) {
                    return result
                }
            }
            guard !Task.isCancelled else { return .failed }
            // A seek near the end can land past the last key frame.
            guard hasKeyframe else { return acceptsLateStart ? .failed : .landedLate }
            // The end of the file (or of the scan): the last decoded frame stays on screen.
            try? decoder.send(nil)
            if let result = receiveFrames(upTo: limit, keeping: &kept, acceptsLateStart: acceptsLateStart) {
                return result
            }
            return kept.map { .found($0) } ?? .failed
        }

        /// Returns a result once a frame after `limit` shows which one was on screen.
        private func receiveFrames(upTo limit: TimeInterval, keeping kept: inout Frame?, acceptsLateStart: Bool)
            -> Scan?
        {
            while (try? decoder.receiveTolerantly(into: decoded)) == true {
                let time = FFmpegTime.seconds(decoded.bestEffortTimestamp, in: stream.timeBase)
                if let time, time > limit {
                    if let kept { return .found(kept) }
                    guard acceptsLateStart else { return .landedLate }
                }
                guard let frame = kept ?? (try? Frame()) else { return .failed }
                frame.take(decoded)
                kept = frame
                if let time, time > limit { return .found(frame) }
            }
            return nil
        }

        private func seconds(of packet: Packet) -> TimeInterval? {
            FFmpegTime.seconds(packet.time, in: stream.timeBase)
        }
    }
}

extension Frame {
    /// Moves `other`'s picture into this frame, leaving `other` empty for the next decode.
    fileprivate func take(_ other: Frame) {
        av_frame_unref(pointer)
        av_frame_move_ref(pointer, other.pointer)
    }
}
