import SwiftUI
import TrimlineCore

/// Thumbnails placed by time, so an older strip stays in place, stretched, under a new one that is loading.
struct ThumbnailStrip: View {
    private enum Metrics {
        static let separatorWidth: CGFloat = 1
        static let separatorOpacity = 0.35
        static let placeholderOpacity = 0.04
        static let minimumSlotWidth: CGFloat = 0.5
    }

    let current: ThumbnailSet
    let previous: ThumbnailSet?
    let viewport: TimelineViewport
    /// The width of one thumbnail at the track's height; a stretched slot repeats its image at this width.
    let tileWidth: CGFloat

    var body: some View {
        Canvas { context, size in
            context.fill(
                Path(CGRect(origin: .zero, size: size)), with: .color(.primary.opacity(Metrics.placeholderOpacity)))
            if let previous {
                draw(previous, in: context, size: size)
            }
            draw(current, in: context, size: size)
        }
    }

    private func draw(_ set: ThumbnailSet, in context: GraphicsContext, size: CGSize) {
        for (index, thumbnail) in set.images.enumerated() {
            guard let thumbnail else { continue }
            let slot = set.slot(index)
            let minX = CGFloat(viewport.fraction(of: slot.lowerBound)) * size.width
            let maxX = CGFloat(viewport.fraction(of: slot.upperBound)) * size.width
            guard maxX > 0, minX < size.width, maxX - minX >= Metrics.minimumSlotWidth else { continue }
            let tileCount = max(1, ((maxX - minX) / max(tileWidth, 1)).rounded())
            let width = (maxX - minX) / tileCount
            let firstTile = max(0, ((0 - minX) / width).rounded(.down))
            let lastTile = min(tileCount, ((size.width - minX) / width).rounded(.up))
            let image = context.resolve(Image(decorative: thumbnail.image, scale: 1))
            for tile in stride(from: firstTile, to: lastTile, by: 1) {
                let rect = CGRect(x: minX + tile * width, y: 0, width: width, height: size.height)
                drawTile(image, in: rect, context: context)
            }
        }
    }

    private func drawTile(_ image: GraphicsContext.ResolvedImage, in rect: CGRect, context: GraphicsContext) {
        guard image.size.width > 0, image.size.height > 0 else { return }
        let scale = max(rect.width / image.size.width, rect.height / image.size.height)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let fill = CGRect(
            x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height)
        var tile = context
        tile.clip(to: Path(rect))
        tile.draw(image, in: fill)
        let separator = CGRect(
            x: rect.maxX - Metrics.separatorWidth, y: rect.minY, width: Metrics.separatorWidth, height: rect.height)
        tile.fill(Path(separator), with: .color(.black.opacity(Metrics.separatorOpacity)))
    }
}

/// Bars sit on a fixed time grid, so scrolling slides them instead of resampling them.
struct WaveformView: View {
    private enum Metrics {
        static let barWidth: CGFloat = 2
        static let barPitch: CGFloat = 3.6
        static let barCornerRadius: CGFloat = 1
        static let minimumBarHeight: CGFloat = 1
        static let verticalFill: CGFloat = 0.9
        // Quiet recordings are scaled up to the loudest peak so their shape stays readable.
        static let silenceThreshold: Float = 0.001
    }

    let peaks: [Peak]
    let viewport: TimelineViewport

    var body: some View {
        Canvas { context, size in
            guard !peaks.isEmpty, size.width > 0, viewport.span > 0 else { return }
            let loudest = max(loudness(of: peaks[...]), Metrics.silenceThreshold)
            let barDuration = viewport.span * Metrics.barPitch / size.width
            let firstBar = Int((viewport.start / barDuration).rounded(.down))
            let lastBar = Int((viewport.end / barDuration).rounded(.up))
            for bar in firstBar..<max(firstBar, lastBar) {
                let time = Double(bar) * barDuration
                let level = CGFloat(min(loudness(of: peaks(from: time, to: time + barDuration)) / loudest, 1))
                let height = max(Metrics.minimumBarHeight, level * size.height * Metrics.verticalFill)
                let rect = CGRect(
                    x: CGFloat(viewport.fraction(of: time)) * size.width + (Metrics.barPitch - Metrics.barWidth) / 2,
                    y: (size.height - height) / 2,
                    width: Metrics.barWidth,
                    height: height
                )
                context.fill(Path(roundedRect: rect, cornerRadius: Metrics.barCornerRadius), with: .style(.tint))
            }
        }
    }

    // When zoomed past the waveform's resolution, neighbouring bars share one bucket.
    private func peaks(from start: TimeInterval, to end: TimeInterval) -> ArraySlice<Peak> {
        let bucketsPerSecond = Double(peaks.count) / viewport.duration
        let first = min(max(Int(start * bucketsPerSecond), 0), peaks.count - 1)
        let last = min(max(Int((end * bucketsPerSecond).rounded(.up)), first + 1), peaks.count)
        return peaks[first..<last]
    }

    private func loudness(of slice: ArraySlice<Peak>) -> Float {
        slice.reduce(0) { result, peak in max(result, abs(peak.min), abs(peak.max)) }
    }
}
