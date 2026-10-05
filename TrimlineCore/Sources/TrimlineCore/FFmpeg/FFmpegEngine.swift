import CoreGraphics
import Foundation

// Timeline time 0 is the file's earliest timestamp (see Demuxer.timelineOrigin).
final class FFmpegEngine: MediaEngine {
    let info: MediaInfo

    private let thumbnailGenerator: FFmpegThumbnailGenerator?
    private let keyframeLocator: FFmpegKeyframeLocator?
    private let frameGrabber: FFmpegFrameGrabber?
    private let waveformBuilder: FFmpegWaveformBuilder

    static func open(
        _ url: URL,
        waveformCache: WaveformCache = WaveformCache()
    ) async throws(MediaOpenError) -> any MediaEngine {
        FFmpegEngine(probe: try FFmpegProbe.run(url), waveformCache: waveformCache)
    }

    private init(probe: FFmpegProbe, waveformCache: WaveformCache) {
        info = probe.info
        let url = probe.info.url
        thumbnailGenerator = probe.video.map {
            FFmpegThumbnailGenerator(
                url: url, video: $0, timelineOrigin: probe.timelineOrigin, duration: probe.info.duration)
        }
        keyframeLocator = probe.video.map {
            FFmpegKeyframeLocator(url: url, streamIndex: $0.index, timelineOrigin: probe.timelineOrigin)
        }
        frameGrabber = probe.video.map {
            FFmpegFrameGrabber(url: url, video: $0, timelineOrigin: probe.timelineOrigin)
        }
        waveformBuilder = FFmpegWaveformBuilder(
            url: url,
            streamIndex: probe.audioStreamIndex,
            duration: probe.info.duration,
            cache: waveformCache,
            fileIdentity: probe.fileIdentity
        )
    }

    @MainActor func makePlayback() -> any PlaybackController {
        FFmpegPlaybackController(url: info.url, info: info)
    }

    func thumbnails(count: Int, height: Int, in range: ClosedRange<TimeInterval>) -> AsyncStream<Thumbnail> {
        guard let thumbnailGenerator else { return AsyncStream { $0.finish() } }
        return thumbnailGenerator.thumbnails(count: count, height: height, in: range)
    }

    func peaks(buckets: Int) -> AsyncStream<PeakChunk> {
        waveformBuilder.peaks(buckets: buckets)
    }

    func keyframe(atOrBefore time: TimeInterval) async -> TimeInterval {
        guard let keyframeLocator else { return time }
        return await keyframeLocator.keyframe(atOrBefore: time) ?? time
    }

    func frameImage(at time: TimeInterval) async -> CGImage? {
        await frameGrabber?.image(at: time)
    }
}
