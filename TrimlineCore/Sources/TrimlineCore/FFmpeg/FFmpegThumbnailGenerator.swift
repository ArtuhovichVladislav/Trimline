import Foundation

actor FFmpegThumbnailGenerator {
    private let url: URL
    private let video: FFmpegProbe.VideoStream
    private let timelineOrigin: TimeInterval
    private let duration: TimeInterval
    private var decoder: FFmpegKeyframeDecoder?
    private let queue = BlockingWork.queue(for: FFmpegThumbnailGenerator.self)

    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    init(url: URL, video: FFmpegProbe.VideoStream, timelineOrigin: TimeInterval, duration: TimeInterval) {
        self.url = url
        self.video = video
        self.timelineOrigin = timelineOrigin
        self.duration = duration
    }

    nonisolated func thumbnails(count: Int, height: Int, in range: ClosedRange<TimeInterval>) -> AsyncStream<Thumbnail>
    {
        AsyncStream { continuation in
            let task = Task {
                await self.generate(count: count, height: height, range: range, into: continuation)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Private

    private func generate(
        count: Int,
        height: Int,
        range: ClosedRange<TimeInterval>,
        into continuation: AsyncStream<Thumbnail>.Continuation
    ) {
        guard count > 0, height > 0, let decoder = openDecoder() else { return }
        for (index, time) in ThumbnailGenerator.requestTimes(count: count, in: range).enumerated() {
            guard !Task.isCancelled else { return }
            guard let picture = decoder.picture(at: timelineOrigin + time, height: height) else { continue }
            let pictureTime = picture.time.map { $0 - timelineOrigin } ?? time
            continuation.yield(Thumbnail(index: index, time: min(max(0, pictureTime), duration), image: picture.image))
        }
    }

    private func openDecoder() -> FFmpegKeyframeDecoder? {
        if let decoder { return decoder }
        decoder = try? FFmpegKeyframeDecoder(url: url, video: video)
        return decoder
    }
}
