import Foundation

/// Where copying starts: the seek point and the first packet of the primary stream to keep.
struct RemuxStart {
    let seek: SeekPoint
    let firstTime: Int64
    /// The primary stream begins after the requested start, so the clip starts where asked.
    let startsLater: Bool

    static func locate(
        in demuxer: Demuxer, track: RemuxTrack, at time: TimeInterval, isCancelled: Remuxer.Cancellation
    ) throws(FFmpegError) -> RemuxStart {
        let search = KeyframeSearch(
            streamIndex: track.inputIndex, timeBase: track.inputTimeBase, needsKeyframe: track.role == .video)
        guard let found = try search.locate(in: demuxer, at: time, isCancelled: isCancelled) else {
            throw RemuxStop.noStreams
        }
        return RemuxStart(seek: found.seek, firstTime: found.timestamp, startsLater: found.startsLater)
    }
}
