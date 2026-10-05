import Foundation
import libavcodec
import libavformat
import libavutil

/// Precise saving without re-encoding the whole picture (decision 0009). The head, from the start of the
/// clip to the junction (the next key frame a copy can start from), is encoded again; so is the outro, the
/// few frames before the end that refer to frames shown after it. Everything between is copied.
struct SmartCut {
    struct Outro {
        /// The first re-encoded frame, in the source stream's time base.
        let start: Int64
        /// The key frame its decoder starts from.
        let decodeFrom: Int64
        let encoder: Encoder
    }

    let bitstream: NALBitstream
    /// The first copied picture, in the source stream's time base.
    let junction: Int64
    /// The first packet in decode order that is no longer copied; `nil` copies to the end of the stream.
    let stop: Int64?
    /// How far decode times run ahead of presentation in the copy; the encoded parts are stamped the same
    /// way, so decode times keep increasing across both seams.
    let delay: Int64
    /// Opened only when the clip doesn't start right on the junction.
    let headEncoder: Encoder?
    let outro: Outro?

    var reencodes: Bool { headEncoder != nil || outro != nil }

    // Containers where the mixed stream was checked to decode in FFmpeg, in the app's player and, for
    // QuickTime, in AVFoundation. AVFoundation's HEVC decoder refuses parameter sets that differ from the
    // sample description, and this libavformat writes only one description per track.
    private static let muxers: [UInt32: Set<String>] = [
        AV_CODEC_ID_H264.rawValue: ["matroska", "mpegts", "mov", "mp4", "ipod"],
        AV_CODEC_ID_HEVC.rawValue: ["matroska", "mpegts"],
    ]
    private static let boundaryTolerance = KeyframeSearch.matchTolerance
    // Past this a stream without clean key frames (open-GOP H.264) is cheaper to encode than to search.
    private static let maximumHead: TimeInterval = 300
    // Far more than any reordering: once this many packets past the end are seen, nothing shown before
    // the end can follow.
    private static let packetsPastEnd = 32
    private static let exitAttempts = 4

    /// Plans the cut of `range` (source seconds), read from `start`. Returns `nil` when the whole picture
    /// has to be encoded: another codec, profile or depth than the hardware encoder writes, an untested
    /// container, or no clean key frame between the start and the end.
    static func locate(
        in demuxer: Demuxer, stream: Demuxer.Stream, container: ExportContainer, start: RemuxStart,
        range: ClosedRange<TimeInterval>, isCancelled: Remuxer.Cancellation
    ) throws(FFmpegError) -> SmartCut? {
        guard muxers[stream.codecID.rawValue]?.contains(container.muxer) == true,
            let source = demuxer.stream(stream.index), let profile = headProfile(of: stream.parameters.pointee),
            let bitstream = NALBitstream(parameters: stream.parameters.pointee)
        else { return nil }
        let scanner = Scanner(demuxer: demuxer, stream: stream)
        let timeBase = stream.timeBase
        let headLimit = min(range.upperBound, range.lowerBound + maximumHead)
        guard
            let junction = try scanner.junction(
                after: range.lowerBound - boundaryTolerance, before: headLimit, from: start, bitstream: bitstream,
                isCancelled: isCancelled),
            let exit = try scanner.exit(
                before: range.upperBound - boundaryTolerance, junction: junction.pts, isCancelled: isCancelled)
        else { return nil }

        let hasHead = junction.pts > FFmpegTime.timestamp(range.lowerBound + boundaryTolerance, in: timeBase)
        // Matroska leaves decode times to be guessed right after a seek; an encoded part needs a real one.
        guard let delay = hasHead ? junction.delay : (exit.outroStart == nil ? 0 : exit.delay) else { return nil }
        let settings = VideoEncoderSettings(stream: stream, in: demuxer, encoding: Encoding.video(for: stream.codecID))
        func encoder() -> Encoder? { try? settings.makeHeadEncoder(for: source, profile: profile) }
        var outro: Outro?
        if let outroStart = exit.outroStart {
            guard let encoder = encoder() else { return nil }
            outro = Outro(start: outroStart, decodeFrom: exit.decodeFrom, encoder: encoder)
        }
        let headEncoder = hasHead ? encoder() : nil
        guard headEncoder != nil || !hasHead else { return nil }
        return SmartCut(
            bitstream: bitstream, junction: junction.pts, stop: exit.stop, delay: delay, headEncoder: headEncoder,
            outro: outro)
    }

    /// The source's profile, if the hardware encoder writes it: H.264 Baseline, Main and High, HEVC Main and
    /// Main 10, all progressive 4:2:0.
    private static func headProfile(of parameters: AVCodecParameters) -> Int32? {
        guard parameters.field_order == AV_FIELD_PROGRESSIVE || parameters.field_order == AV_FIELD_UNKNOWN,
            parameters.width > 0, parameters.height > 0
        else { return nil }
        let format = AVPixelFormat(rawValue: parameters.format)
        let isEightBit = [AV_PIX_FMT_YUV420P, AV_PIX_FMT_YUVJ420P].contains(format)
        let profiles: Set<Int32> =
            switch parameters.codec_id {
            case AV_CODEC_ID_H264 where isEightBit:
                [
                    AV_PROFILE_H264_CONSTRAINED_BASELINE, AV_PROFILE_H264_BASELINE, AV_PROFILE_H264_MAIN,
                    AV_PROFILE_H264_HIGH,
                ]
            case AV_CODEC_ID_HEVC where isEightBit: [AV_PROFILE_HEVC_MAIN]
            case AV_CODEC_ID_HEVC where format == AV_PIX_FMT_YUV420P10LE: [AV_PROFILE_HEVC_MAIN_10]
            default: []
            }
        return profiles.contains(parameters.profile) ? parameters.profile : nil
    }

    /// Reads the picture's packets around the seams before anything is written.
    private struct Scanner {
        struct Junction {
            let pts: Int64
            let delay: Int64?
        }

        struct Exit {
            let stop: Int64?
            let outroStart: Int64?
            let decodeFrom: Int64
            let delay: Int64?
        }

        private struct Entry {
            let pts: Int64
            let delay: Int64?
            let isKeyframe: Bool
        }

        let demuxer: Demuxer
        let stream: Demuxer.Stream

        /// The first key frame from `after` on that a copy can start from: an IDR picture in H.264, any random
        /// access picture in HEVC (its leading pictures go to the head).
        func junction(
            after: TimeInterval, before: TimeInterval, from start: RemuxStart, bitstream: NALBitstream,
            isCancelled: Remuxer.Cancellation
        ) throws(FFmpegError) -> Junction? {
            let origin = FFmpegTime.timestamp(after, in: stream.timeBase)
            let limit = FFmpegTime.timestamp(before, in: stream.timeBase)
            let reader = try demuxer.positioned(at: start.seek, streamIndex: stream.index)
            let packet = try Packet()
            while try next(into: packet, from: reader, isCancelled: isCancelled) {
                let decodeTime = packet.dts != FFmpegTime.noValue ? packet.dts : packet.pts
                if decodeTime != FFmpegTime.noValue, decodeTime >= limit { return nil }
                guard packet.isKeyframe, packet.pts != FFmpegTime.noValue, packet.pts >= origin,
                    bitstream.startsCleanly(packet)
                else { continue }
                return Junction(pts: packet.pts, delay: Self.delay(of: packet))
            }
            return nil
        }

        /// Where the copy ends. Frames shown before the end may refer to frames shown after it, so the copy
        /// stops at the last point in decode order where everything before is shown before everything after,
        /// and the frames from there to the end become the outro.
        func exit(before end: TimeInterval, junction: Int64, isCancelled: Remuxer.Cancellation) throws(FFmpegError)
            -> Exit?
        {
            let endTime = FFmpegTime.timestamp(end, in: stream.timeBase)
            let track = RemuxTrack(
                inputIndex: stream.index, outputIndex: -1, role: .video, inputTimeBase: stream.timeBase,
                outputTimeBase: stream.timeBase)
            var target = end
            for _ in 0..<exitAttempts {
                let keyframe = try RemuxStart.locate(in: demuxer, track: track, at: target, isCancelled: isCancelled)
                let from = max(keyframe.firstTime, junction)
                let entries = try scan(from: from, seek: keyframe.seek, end: endTime, isCancelled: isCancelled)
                if let exit = Self.exit(in: entries, end: endTime) { return exit }
                if from <= junction { return nil }
                target = (FFmpegTime.seconds(from, in: stream.timeBase) ?? 0) - boundaryTolerance
            }
            return nil
        }

        private func scan(
            from first: Int64, seek: SeekPoint, end: Int64, isCancelled: Remuxer.Cancellation
        ) throws(FFmpegError) -> [Entry] {
            let reader = try demuxer.positioned(at: seek, streamIndex: stream.index)
            let packet = try Packet()
            var entries: [Entry] = []
            var pastEnd = 0
            while pastEnd < packetsPastEnd, try next(into: packet, from: reader, isCancelled: isCancelled) {
                guard !entries.isEmpty || (packet.isKeyframe && packet.pts == first) else { continue }
                guard packet.pts != FFmpegTime.noValue else { return [] }
                entries.append(Entry(pts: packet.pts, delay: Self.delay(of: packet), isKeyframe: packet.isKeyframe))
                if packet.pts >= end { pastEnd += 1 }
            }
            return entries
        }

        private static func exit(in entries: [Entry], end: Int64) -> Exit? {
            guard let first = entries.first else { return nil }
            var smallestAfter = Array(repeating: Int64.max, count: entries.count + 1)
            for index in entries.indices.reversed() {
                smallestAfter[index] = min(entries[index].pts, smallestAfter[index + 1])
            }
            var largestBefore = Int64.min
            var best: Int?
            for count in 1...entries.count {
                largestBefore = max(largestBefore, entries[count - 1].pts)
                guard largestBefore < end else { break }
                if largestBefore < smallestAfter[count] { best = count }
            }
            guard let best else { return nil }
            let stop = best < entries.count ? entries[best].pts : nil
            let outroStart = smallestAfter[best] < end ? smallestAfter[best] : nil
            let delay = entries.first { $0.isKeyframe && $0.delay != nil }?.delay
            return Exit(stop: stop, outroStart: outroStart, decodeFrom: first.pts, delay: delay)
        }

        private func next(into packet: Packet, from reader: Demuxer, isCancelled: Remuxer.Cancellation)
            throws(FFmpegError) -> Bool
        {
            while try reader.read(into: packet) {
                guard !isCancelled() else { throw RemuxStop.cancelled }
                if packet.streamIndex == stream.index { return true }
            }
            return false
        }

        private static func delay(of packet: Packet) -> Int64? {
            guard packet.dts != FFmpegTime.noValue, packet.pts != FFmpegTime.noValue, packet.dts <= packet.pts else {
                return nil
            }
            return try? FFmpegTime.difference(packet.pts, packet.dts)
        }
    }
}
