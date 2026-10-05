import AVFoundation
import Foundation

final class AVFoundationEngine: MediaEngine {
    let info: MediaInfo

    private let asset: AVURLAsset
    private let videoTrack: AssetProbe.VideoTrackReference?
    private let thumbnailGenerator: ThumbnailGenerator
    private let waveformBuilder: WaveformBuilder

    // One sample per step; 3000 frames is almost two minutes at 30 fps, longer than any real GOP.
    static let maximumKeyframeSearchSteps = 3_000
    // UI times are rounded doubles. Without slack a start exactly on a key frame can land a tick
    // before it and snap to the previous key frame.
    static let keyframeMatchTolerance: TimeInterval = 0.000_5

    static func open(
        _ url: URL,
        waveformCache: WaveformCache = WaveformCache()
    ) async throws(MediaOpenError) -> any MediaEngine {
        AVFoundationEngine(probe: try await AssetProbe.run(url), waveformCache: waveformCache)
    }

    private init(probe: AssetProbe, waveformCache: WaveformCache) {
        info = probe.info
        asset = probe.asset
        videoTrack = probe.videoTrack
        thumbnailGenerator = ThumbnailGenerator(asset: probe.asset, displaySize: probe.info.displaySize)
        waveformBuilder = WaveformBuilder(
            asset: probe.asset,
            duration: probe.info.duration,
            cache: waveformCache,
            fileIdentity: probe.fileIdentity
        )
    }

    @MainActor func makePlayback() -> any PlaybackController {
        AVPlaybackController(asset: asset, showsVideo: info.kind == .video)
    }

    func thumbnails(count: Int, height: Int, in range: ClosedRange<TimeInterval>) -> AsyncStream<Thumbnail> {
        thumbnailGenerator.thumbnails(count: count, height: height, in: range)
    }

    func peaks(buckets: Int) -> AsyncStream<PeakChunk> {
        waveformBuilder.peaks(buckets: buckets)
    }

    func keyframe(atOrBefore time: TimeInterval) async -> TimeInterval {
        guard let videoTrack,
            let track = try? await asset.loadTrack(withTrackID: videoTrack.id),
            (try? await track.load(.canProvideSampleCursors)) == true
        else { return time }

        let target = CMTime(seconds: time + Self.keyframeMatchTolerance, preferredTimescale: videoTrack.timescale)
        guard let cursor = track.makeSampleCursor(presentationTimeStamp: target) else { return time }
        return Self.syncSampleTime(from: cursor, atOrBefore: target) ?? time
    }

    // The default dynamic range policy tone-maps PQ and HLG to SDR; the default aperture mode applies
    // the pixel aspect ratio, as the player layer does.
    func frameImage(at time: TimeInterval) async -> CGImage? {
        guard info.kind == .video else { return nil }
        let request = FrameRequest(asset: asset)
        let lastFrameTime = max(0, info.duration - info.frameStep)
        return await withTaskCancellationHandler {
            if let image = await request.image(at: time) {
                return image
            }
            // At the very end of the file no frame starts at or before the requested time.
            guard time > lastFrameTime, !Task.isCancelled else { return nil }
            return await request.image(at: lastFrameTime)
        } onCancel: {
            request.cancel()
        }
    }

    // With imprecise timing the cursor may start slightly after the target, so the time is checked too.
    private static func syncSampleTime(from cursor: AVSampleCursor, atOrBefore target: CMTime) -> TimeInterval? {
        for _ in 0..<maximumKeyframeSearchSteps {
            if cursor.presentationTimeStamp <= target, cursor.currentSampleSyncInfo.sampleIsFullSync.boolValue {
                return max(0, cursor.presentationTimeStamp.seconds)
            }
            guard cursor.stepInPresentationOrder(byCount: -1) == -1 else { return nil }
        }
        return nil
    }
}

// AVAssetImageGenerator may be cancelled from any thread.
private final class FrameRequest: @unchecked Sendable {
    private let generator: AVAssetImageGenerator

    init(asset: AVAsset) {
        generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
    }

    func image(at time: TimeInterval) async -> CGImage? {
        try? await generator.image(at: CMTime(engineSeconds: time)).image
    }

    func cancel() {
        generator.cancelAllCGImageGeneration()
    }
}

extension CMTime {
    // The MPEG system clock: exact for every common frame and sample rate.
    static let engineTimescale: CMTimeScale = 90_000

    init(engineSeconds seconds: TimeInterval) {
        self = CMTime(seconds: seconds, preferredTimescale: Self.engineTimescale)
    }
}
