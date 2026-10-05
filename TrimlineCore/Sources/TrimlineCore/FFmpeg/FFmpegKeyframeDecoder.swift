import CoreGraphics
import Foundation
import libavcodec

// Decodes single key frames for thumbnails. Not thread-safe: owned by one FFmpegThumbnailGenerator.
final class FFmpegKeyframeDecoder {
    struct Picture {
        /// Seconds in the file's own clock, before the timeline origin is subtracted.
        let time: TimeInterval?
        let image: CGImage
    }

    private let demuxer: Demuxer
    private let decoder: Decoder
    private let stream: Demuxer.Stream
    private let renderer: FrameImageRenderer
    private let packet: Packet
    private let candidate: Packet
    private let frame: Frame
    private var reusable: (packetTime: Int64, height: Int, picture: Picture)?

    // Some streams flag key frames the decoder still refuses (open-GOP recovery points); give up
    // on a slot after this many packets rather than reading on through the file.
    private static let maximumPacketsPerPicture = 600
    private static let lookbacks: [TimeInterval] = [2, 10]
    // Container timestamps are rounded (Matroska to milliseconds).
    private static let timeTolerance: TimeInterval = 0.001

    init(url: URL, video: FFmpegProbe.VideoStream) throws(FFmpegError) {
        demuxer = try Demuxer(url: url)
        guard let stream = demuxer.streams.first(where: { $0.index == video.index }) else { throw .invalidData }
        demuxer.discardAllStreams(except: video.index)
        self.stream = stream
        decoder = try Decoder(stream: stream)
        decoder.decodesKeyframesOnly = true
        packet = try Packet()
        candidate = try Packet()
        frame = try Frame()
        renderer = FrameImageRenderer(
            quarterTurns: video.quarterTurns,
            displayAspectRatio: video.displaySize.flatMap { $0.height > 0 ? $0.width / $0.height : nil }
        )
    }

    /// The key frame at or before `time` (file clock), at most `height` pixels tall in display orientation.
    func picture(at time: TimeInterval, height: Int) -> Picture? {
        if let picture = keyframeAtSeekPoint(before: time, height: height) { return picture }
        // Seeks can miss: MPEG-TS bisects by decode timestamps and may land a GOP late, and near the end
        // of a file there is no later key frame at all. Then read forward from a little earlier.
        for lookback in Self.lookbacks {
            let start = max(0, time - lookback)
            if let picture = lastKeyframe(before: time, from: start, height: height) { return picture }
            if start == 0 { break }
        }
        return nil
    }

    // MARK: Private

    private func keyframeAtSeekPoint(before time: TimeInterval, height: Int) -> Picture? {
        try? demuxer.seek(streamIndex: stream.index, to: time)
        var scanned = 0
        while readVideoPacket(counting: &scanned) {
            guard packet.isKeyframe else { continue }
            guard (seconds(of: packet) ?? time) <= time + Self.timeTolerance else { return nil }
            if let picture = picture(decoding: packet, height: height) { return picture }
        }
        return nil
    }

    private func lastKeyframe(before time: TimeInterval, from start: TimeInterval, height: Int) -> Picture? {
        try? demuxer.seek(streamIndex: stream.index, to: start)
        var scanned = 0
        var hasCandidate = false
        while readVideoPacket(counting: &scanned) {
            guard packet.isKeyframe else { continue }
            let isAfterTime = (seconds(of: packet) ?? time) > time
            if isAfterTime, hasCandidate { break }
            hasCandidate = candidate.reference(packet)
            if isAfterTime { break }
        }
        return hasCandidate ? picture(decoding: candidate, height: height) : nil
    }

    private func readVideoPacket(counting scanned: inout Int) -> Bool {
        while scanned < Self.maximumPacketsPerPicture, (try? demuxer.read(into: packet)) == true {
            guard packet.streamIndex == stream.index else { continue }
            scanned += 1
            return true
        }
        return false
    }

    private func picture(decoding packet: Packet, height: Int) -> Picture? {
        let packetTime = packet.time
        // Neighbouring slots inside one long GOP land on the same key frame.
        if let reusable, packetTime != FFmpegTime.noValue, reusable.packetTime == packetTime, reusable.height == height
        {
            return reusable.picture
        }
        guard let image = decode(packet, height: height) else { return nil }
        let picture = Picture(time: FFmpegTime.seconds(frame.bestEffortTimestamp, in: stream.timeBase), image: image)
        reusable = (packetTime, height, picture)
        return picture
    }

    private func decode(_ packet: Packet, height: Int) -> CGImage? {
        defer { decoder.flush() }
        do {
            try decoder.send(packet)
            if try !decoder.receive(into: frame) {
                // Draining makes frame-threaded decoders hand the picture over now, not several packets later.
                try decoder.send(nil)
                guard try decoder.receive(into: frame) else { return nil }
            }
        } catch {
            return nil
        }
        return renderer.image(of: frame, height: height)
    }

    private func seconds(of packet: Packet) -> TimeInterval? {
        FFmpegTime.seconds(packet.time, in: stream.timeBase)
    }
}

extension Packet {
    /// Makes this packet share `other`'s data, so it survives the next read into `other`.
    fileprivate func reference(_ other: Packet) -> Bool {
        unref()
        return av_packet_ref(pointer, other.pointer) >= 0
    }
}
