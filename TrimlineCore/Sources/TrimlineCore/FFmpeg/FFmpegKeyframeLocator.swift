import Foundation

/// Where saving without re-encoding starts a clip, for the start handle and the save panel. It is the same
/// search the Remuxer makes, so the panel shows where the clip really starts.
actor FFmpegKeyframeLocator {
    private let url: URL
    private let streamIndex: Int
    private let timelineOrigin: TimeInterval
    private let queue = BlockingWork.queue(for: FFmpegKeyframeLocator.self)
    private var demuxer: Demuxer?

    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    init(url: URL, streamIndex: Int, timelineOrigin: TimeInterval) {
        self.url = url
        self.streamIndex = streamIndex
        self.timelineOrigin = timelineOrigin
    }

    /// `nil` when there is no key frame to find. A stream that begins after `time` has nothing to snap to:
    /// the clip starts at `time` itself.
    func keyframe(atOrBefore time: TimeInterval) -> TimeInterval? {
        guard let demuxer = openDemuxer(),
            let timeBase = demuxer.streams.first(where: { $0.index == streamIndex })?.timeBase
        else { return nil }
        let search = KeyframeSearch(streamIndex: streamIndex, timeBase: timeBase, needsKeyframe: true)
        guard let found = try? search.locate(in: demuxer, at: timelineOrigin + time, isCancelled: { Task.isCancelled })
        else { return nil }
        if found.startsLater { return time }
        return FFmpegTime.seconds(found.timestamp, in: timeBase).map { max(0, $0 - timelineOrigin) }
    }

    // MARK: Private

    private func openDemuxer() -> Demuxer? {
        if let demuxer { return demuxer }
        guard let opened = try? Demuxer(url: url) else { return nil }
        opened.discardAllStreams(except: streamIndex)
        demuxer = opened
        return opened
    }
}
