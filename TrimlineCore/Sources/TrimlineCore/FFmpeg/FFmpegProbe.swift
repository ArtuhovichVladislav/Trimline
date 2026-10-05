import CoreGraphics
import Foundation
import libavcodec
import libavformat
import libavutil

struct FFmpegProbe: Sendable {
    struct VideoStream: Sendable {
        let index: Int
        let displaySize: CGSize?
        /// Clockwise quarter turns, 0...3.
        let quarterTurns: Int
    }

    let info: MediaInfo
    let video: VideoStream?
    let audioStreamIndex: Int?
    let timelineOrigin: TimeInterval
    let fileIdentity: WaveformCache.FileIdentity?

    private static let accessErrorCodes: Set<Int32> = [-ENOENT, -EACCES, -EPERM]

    static func run(_ url: URL) throws(MediaOpenError) -> FFmpegProbe {
        let file = try MediaFile(url)
        let demuxer = try openDemuxer(url)
        let pictures = demuxer.streams.filter { $0.kind == .video && !$0.isAttachedPicture }
        let sounds = demuxer.streams.filter { $0.kind == .audio }
        guard !pictures.isEmpty || !sounds.isEmpty else { throw .noAudioOrVideo }

        // A video file with an undecodable picture is reported as unsupported even if its sound would play.
        let picture = try firstDecodable(of: pictures)
        let sound = sounds.first(where: hasDecoder)
        if picture == nil, sound == nil, let first = sounds.first {
            throw .unsupportedCodec(FFmpegCodecName.displayName(for: first))
        }

        let video = picture.map { describeVideo($0, in: demuxer) }
        let duration = demuxer.duration ?? demuxer.streams.compactMap(\.duration).max() ?? 0
        let reportedBitRate = Double(demuxer.bitRate)
        let info = MediaInfo(
            url: url,
            kind: video == nil ? .audio : .video,
            duration: duration,
            fileSize: file.size,
            displaySize: video?.displaySize,
            frameRate: picture.flatMap { frameRate(of: $0, in: demuxer) },
            estimatedBitRate: reportedBitRate > 0 ? reportedBitRate : file.averageBitRate(duration: duration),
            hasAudio: !sounds.isEmpty,
            audioBitRate: sounds.contains { $0.bitRate <= 0 } ? 0 : Double(sounds.reduce(0) { $0 + $1.bitRate })
        )
        return FFmpegProbe(
            info: info,
            video: video,
            audioStreamIndex: sound?.index,
            timelineOrigin: demuxer.timelineOrigin,
            fileIdentity: file.waveformIdentity
        )
    }

    // MARK: Private

    private static func openDemuxer(_ url: URL) throws(MediaOpenError) -> Demuxer {
        do {
            return try Demuxer(url: url)
        } catch {
            throw accessErrorCodes.contains(error.code) ? .unreadable : .damaged
        }
    }

    private static func hasDecoder(_ stream: Demuxer.Stream) -> Bool {
        avcodec_find_decoder(stream.codecID) != nil
    }

    private static func firstDecodable(of streams: [Demuxer.Stream]) throws(MediaOpenError) -> Demuxer.Stream? {
        guard let first = streams.first else { return nil }
        guard let decodable = streams.first(where: hasDecoder) else {
            throw .unsupportedCodec(FFmpegCodecName.displayName(for: first))
        }
        return decodable
    }

    private static func describeVideo(_ stream: Demuxer.Stream, in demuxer: Demuxer) -> VideoStream {
        let quarterTurns = stream.quarterTurns
        var width = Double(stream.width)
        let aspect = av_guess_sample_aspect_ratio(demuxer.context, demuxer.stream(stream.index), nil)
        if aspect.num > 0, aspect.den > 0 {
            width = (width * Double(aspect.num) / Double(aspect.den)).rounded()
        }
        let height = Double(stream.height)
        let size =
            quarterTurns.isMultiple(of: 2) ? CGSize(width: width, height: height) : CGSize(width: height, height: width)
        let isKnown = width > 0 && height > 0
        return VideoStream(index: stream.index, displaySize: isKnown ? size : nil, quarterTurns: quarterTurns)
    }

    private static func frameRate(of stream: Demuxer.Stream, in demuxer: Demuxer) -> Double? {
        let guessed = av_guess_frame_rate(demuxer.context, demuxer.stream(stream.index), nil)
        guard guessed.num > 0, guessed.den > 0 else { return stream.frameRate }
        return Double(guessed.num) / Double(guessed.den)
    }
}
