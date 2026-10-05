import Foundation
import libavcodec
import libavformat
import libavutil

enum RemuxError: Error {
    case unreadable
    case noStreams
    case cancelled
    case diskFull
    case ffmpeg(FFmpegError)
}

/// Copies a time range of a file into a new file of the given container without re-encoding.
/// Blocking: runs on a thread of its own and checks `isCancelled` on every packet.
struct Remuxer {
    typealias Cancellation = () -> Bool
    typealias Progress = (Double) -> Void

    private static let diskFullCode = -ENOSPC

    let source: URL
    let container: ExportContainer

    func remux(
        _ range: ClosedRange<TimeInterval>, to destination: URL, isCancelled: Cancellation, progress: Progress
    ) throws(RemuxError) -> [SkippedStream] {
        let demuxer: Demuxer
        do {
            demuxer = try Demuxer(url: source)
        } catch {
            throw .unreadable
        }
        // Fills in presentation times some containers (MPEG program streams) leave out.
        demuxer.context.pointee.flags |= AVFMT_FLAG_GENPTS
        do throws(FFmpegError) {
            let output = try RemuxOutput(path: destination.path, muxer: container.muxer)
            var (tracks, skipped) = try output.addStreams(from: demuxer, rules: container.rules)
            guard let primary = Self.primary(of: tracks),
                Self.keepsMainContent(Set(tracks.map(\.role)), of: demuxer, content: container.content)
            else {
                throw RemuxStop.noStreams
            }
            let base = demuxer.timelineOrigin
            let start = try RemuxStart.locate(
                in: demuxer, track: primary, at: base + range.lowerBound - startPreroll(for: primary),
                isCancelled: isCancelled)
            let window = makeWindow(
                start: start, primary: primary, from: base + range.lowerBound,
                to: base + range.upperBound)

            try output.copyMetadata(from: demuxer.context, mapsCameraKeys: container.hasEditList)
            try output.copyChapters(from: demuxer.context, origin: window.origin, end: window.end)
            try output.writeHeader(options: container.muxerOptions)
            for index in tracks.indices {
                tracks[index].outputTimeBase = output.timeBase(ofStream: tracks[index].outputIndex)
            }
            let reader = try demuxer.positioned(at: start.seek, streamIndex: primary.inputIndex)
            var copier = makeCopier(demuxer: reader, output: output, window: window, tracks: tracks)
            try copier.run(isCancelled: isCancelled, progress: progress)
            try output.finish()
            skipped.sort { $0.index < $1.index }
            return skipped
        } catch {
            throw Self.remuxError(error)
        }
    }

    // MARK: Private

    private static func primary(of tracks: [RemuxTrack]) -> RemuxTrack? {
        tracks.first { $0.role == .video } ?? tracks.first { $0.role == .audio }
    }

    /// Extra tracks may be left out, but not all of the picture or all of the sound the clip is to keep.
    static func keepsMainContent(_ kept: Set<RemuxTrack.Role>, of demuxer: Demuxer, content: ExportContent) -> Bool {
        let kinds = Set(demuxer.streams.filter { !$0.isAttachedPicture }.map(\.kind))
        let losesVideo = content.keepsVideo && kinds.contains(.video) && !kept.contains(.video)
        let losesAudio = content.keepsSound && kinds.contains(.audio) && !kept.contains(.audio)
        return !losesVideo && !losesAudio
    }

    private func startPreroll(for primary: RemuxTrack) -> TimeInterval {
        container.hasEditList && primary.role == .audio ? RemuxWindow.audioPreroll.seconds : 0
    }

    private func makeWindow(start: RemuxStart, primary: RemuxTrack, from: TimeInterval, to: TimeInterval)
        -> RemuxWindow
    {
        let first = RemuxTime(value: start.firstTime, timeBase: primary.inputTimeBase)
        let requested = RemuxTime(seconds: from)
        let isExact =
            start.startsLater || (container.hasEditList && first.value(in: requested.timeBase) <= requested.value)
        return RemuxWindow(
            origin: isExact ? requested : first, firstPrimary: first, end: RemuxTime(seconds: to),
            hidesPreroll: container.hasEditList, primaryIndex: primary.inputIndex)
    }

    private func makeCopier(demuxer: Demuxer, output: RemuxOutput, window: RemuxWindow, tracks: [RemuxTrack])
        -> RemuxPacketCopier
    {
        var copier = RemuxPacketCopier(demuxer: demuxer, output: output, window: window, tracks: tracks)
        if container.muxer == FLACStreamInfo.muxer {
            copier.streamInfo = demuxer.stream(window.primaryIndex).flatMap(FLACStreamInfo.init)
            copier.frameNumbers = copier.streamInfo.map { _ in FLACFrameNumbers() }
        }
        if container.muxer == WavPackBlockNumbers.muxer {
            copier.blockNumbers = WavPackBlockNumbers()
        }
        return copier
    }

    static func remuxError(_ error: FFmpegError) -> RemuxError {
        switch error.code {
        case RemuxStop.cancelled.code: .cancelled
        case RemuxStop.noStreams.code, FFmpegError.decoderNotFound.code, FFmpegError.encoderNotFound.code: .noStreams
        case diskFullCode: .diskFull
        default: .ffmpeg(error)
        }
    }
}

/// Our own reasons to stop, carried through the FFmpeg error type so one typed `throws` covers the copy.
/// Built like FFmpeg's own FFERRTAG codes, so they can't clash with a system error number.
enum RemuxStop {
    static let cancelled = FFmpegError(tag: Array("TRCN".utf8))
    static let noStreams = FFmpegError(tag: Array("TRNS".utf8))
}
