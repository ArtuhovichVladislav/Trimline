import Foundation
import libavformat
import libavutil

/// Finds the latest key frame at or before a time by reading packets. A backward seek lands on an index
/// entry, which can be coarser than the real key frames (sparse Matroska cues), missing (Matroska without
/// cues, a broken AVI index) or past the time (MPEG-TS bisects by decode time). So the packets after the
/// landing point are read up to the time, and the search steps further back when the seek overshoots.
/// Saving and the save panel's start both come from here, so the panel shows where the clip really starts.
struct KeyframeSearch {
    struct Result {
        /// Where reading has to start to get the key frame and everything after it.
        let seek: SeekPoint
        /// The key frame's presentation time (decode time when it has none), in the stream's time base.
        let timestamp: Int64
        /// The stream has no key frame at or before the time: it begins later, with `timestamp`. Other
        /// streams may have data before it, so reading starts at the beginning of the file.
        let startsLater: Bool
    }

    // A start exactly on a key frame must not go back to the previous one.
    static let matchTolerance: TimeInterval = 0.000_5
    private static let lookbacks: [TimeInterval] = [0, 2, 10, 60, .infinity]
    // Over ten minutes of 30 fps video: longer than any real GOP, short enough to stay responsive.
    private static let maximumScannedPackets = 20_000
    // MPEG streams are searched by decode time, and the file's start is the earliest presentation time:
    // with B-frames the first key frame decodes before it, so a seek to the start would skip that GOP.
    private static let decodeTimeSeekers: Set<String> = ["mpegts", "mpeg"]
    private static let decodeLead: TimeInterval = 1

    let streamIndex: Int
    let timeBase: AVRational
    /// Every packet of a sound stream starts cleanly; a picture needs a key frame.
    let needsKeyframe: Bool

    /// `time` is in the file's clock. Returns `nil` when no usable packet of the stream is found.
    func locate(in demuxer: Demuxer, at time: TimeInterval, isCancelled: () -> Bool) throws(FFmpegError) -> Result? {
        let base = demuxer.timelineOrigin
        let floor = base - (Self.decodeTimeSeekers.contains(demuxer.formatName) ? Self.decodeLead : 0)
        let target = FFmpegTime.timestamp(max(base, time) + Self.matchTolerance, in: timeBase)
        let packet = try Packet()
        for lookback in Self.lookbacks {
            let seekTime = max(floor, time - lookback)
            let reachesStart = seekTime <= floor
            var point = SeekPoint.time(seekTime)
            var reader = demuxer
            do {
                try demuxer.seek(streamIndex: streamIndex, to: seekTime)
            } catch {
                guard reachesStart else { continue }
                point = .fileStart
                reader = try demuxer.positioned(at: point, streamIndex: streamIndex)
            }
            let scan = try scan(reader, packet: packet, upTo: target, isCancelled: isCancelled)
            if let best = scan.best {
                return Result(seek: point, timestamp: best, startsLater: false)
            }
            if reachesStart {
                return scan.first.map { Result(seek: .fileStart, timestamp: $0, startsLater: true) }
            }
        }
        return nil
    }

    private struct Scan {
        var best: Int64?
        var first: Int64?
    }

    private func scan(_ demuxer: Demuxer, packet: Packet, upTo target: Int64, isCancelled: () -> Bool)
        throws(FFmpegError) -> Scan
    {
        var scan = Scan()
        var scanned = 0
        while scanned < Self.maximumScannedPackets, try demuxer.read(into: packet) {
            guard !isCancelled() else { throw RemuxStop.cancelled }
            guard packet.streamIndex == streamIndex else { continue }
            scanned += 1
            let time = packet.time
            guard time != FFmpegTime.noValue else { continue }
            if !needsKeyframe || packet.isKeyframe {
                scan.first = scan.first ?? time
                if time <= target { scan.best = max(scan.best ?? time, time) }
            }
            // Decode order is increasing, and no frame shows before it is decoded.
            let decodeTime = needsKeyframe && packet.dts != FFmpegTime.noValue ? packet.dts : time
            if decodeTime > target, scan.first != nil { break }
        }
        return scan
    }
}

/// Where reading starts.
enum SeekPoint: Equatable {
    /// The key frame at or before this moment of the seeked stream (file clock).
    case time(TimeInterval)
    /// The first packet of the file, of any stream.
    case fileStart
}

extension Demuxer {
    private static let initialSeekStep: TimeInterval = 1

    /// A quick seek for readers that need some key frame at or before `target`, not the latest one (playback,
    /// frame grabbing). MPEG-TS bisects by decode time, and FLV and sparse indexes can land after the target:
    /// `land` reads after each seek and returns `nil` for such a landing, and the seek steps back, doubling
    /// the step, down to `streamStart`. Returns `nil` when no seek landed well.
    func seek<Landing>(
        streamIndex: Int, before target: TimeInterval, streamStart: TimeInterval, isCancelled: () -> Bool,
        land: () -> Landing?
    ) -> Landing? {
        var seekTime = target
        var step = Self.initialSeekStep
        while !isCancelled() {
            try? seek(streamIndex: streamIndex, to: max(seekTime, streamStart))
            if let landing = land() { return landing }
            guard seekTime > streamStart else { break }
            seekTime -= step
            step *= 2
        }
        return nil
    }

    /// What to read from at `point`: this demuxer after a seek, or, for the start of the file, this one gone
    /// back to its first byte or a new one.
    func positioned(at point: SeekPoint, streamIndex: Int) throws(FFmpegError) -> Demuxer {
        switch point {
        case .time(let time):
            try seek(streamIndex: streamIndex, to: time)
            return self
        case .fileStart:
            if Self.resumesAfterByteSeek.contains(formatName),
                (try? FFmpegError.check(av_seek_frame(context, -1, 0, AVSEEK_FLAG_BYTE))) != nil
            {
                return self
            }
            return try reopened()
        }
    }

    // A timestamp seek stops at the stream's first index entry (Matroska indexes only the picture, whose first
    // key frame may follow seconds of sound), and after a byte seek most demuxers lose their place: Matroska
    // resumes clusters later. These find the next packet on their own, and going back is cheaper than reopening.
    private static let resumesAfterByteSeek: Set<String> = ["mpegts", "mpeg", "flv"]

    /// The same file with the same flags and discarded streams, read from its first packet.
    func reopened() throws(FFmpegError) -> Demuxer {
        let fresh = try Demuxer(url: url)
        fresh.context.pointee.flags |= context.pointee.flags & AVFMT_FLAG_GENPTS
        for index in 0..<Int(context.pointee.nb_streams) {
            if let discard = stream(index)?.pointee.discard {
                fresh.stream(index)?.pointee.discard = discard
            }
        }
        return fresh
    }
}
