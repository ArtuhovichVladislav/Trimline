import AVFoundation
import CoreGraphics

actor ThumbnailGenerator {
    private let asset: AVURLAsset
    private let aspectRatio: Double

    // Used when the frame size is unknown; the generator never upscales, so a wide box is harmless.
    private static let fallbackAspectRatio = 4.0
    private static let slotCenter = 0.5

    init(asset: AVURLAsset, displaySize: CGSize?) {
        self.asset = asset
        if let displaySize, displaySize.width > 0, displaySize.height > 0 {
            aspectRatio = displaySize.width / displaySize.height
        } else {
            aspectRatio = Self.fallbackAspectRatio
        }
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

    static func requestTimes(count: Int, in range: ClosedRange<TimeInterval>) -> [TimeInterval] {
        guard count > 0 else { return [] }
        let slot = (range.upperBound - range.lowerBound) / Double(count)
        return (0..<count).map { range.lowerBound + (Double($0) + slotCenter) * slot }
    }

    // MARK: Private

    private func generate(
        count: Int,
        height: Int,
        range: ClosedRange<TimeInterval>,
        into continuation: AsyncStream<Thumbnail>.Continuation
    ) async {
        guard count > 0, height > 0 else { return }
        let generator = makeGenerator(height: height)
        let times = Self.requestTimes(count: count, in: range).map { CMTime(engineSeconds: $0) }
        let indices = Dictionary(times.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })

        for await result in generator.images(for: times) {
            guard !Task.isCancelled else {
                generator.cancelAllCGImageGeneration()
                return
            }
            guard let index = indices[result.requestedTime], let image = try? result.image else { continue }
            let actualTime = (try? result.actualTime) ?? result.requestedTime
            continuation.yield(Thumbnail(index: index, time: actualTime.seconds, image: image))
        }
    }

    private func makeGenerator(height: Int) -> AVAssetImageGenerator {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: (Double(height) * aspectRatio).rounded(.up), height: Double(height))
        // Any frame is acceptable, so the generator decodes the nearest key frame and nothing after it.
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity
        return generator
    }
}
