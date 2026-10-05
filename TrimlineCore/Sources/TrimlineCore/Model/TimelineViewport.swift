import Foundation

/// The part of the file the timeline shows: at zoom 1 the whole file, at most `minimumSpan` seconds.
public struct TimelineViewport: Equatable, Sendable {
    public static let minimumSpan: TimeInterval = 1
    public static let zoomLimit: Double = 10_000
    public static let zoomStep: Double = 2
    private static let centerFraction = 0.5
    private static let zoomTolerance = 1e-9

    public let duration: TimeInterval
    public private(set) var start: TimeInterval = 0
    public private(set) var span: TimeInterval

    public init(duration: TimeInterval) {
        self.duration = max(0, duration)
        span = self.duration
    }

    public var end: TimeInterval { start + span }

    public var range: ClosedRange<TimeInterval> { start...end }

    public var zoomLevel: Double { span > 0 ? duration / span : 1 }

    public var maximumZoom: Double {
        duration > Self.minimumSpan ? min(duration / Self.minimumSpan, Self.zoomLimit) : 1
    }

    public var isZoomed: Bool { span < duration }

    public var canZoomIn: Bool { zoomLevel < maximumZoom * (1 - Self.zoomTolerance) }

    public var canZoomOut: Bool { isZoomed }

    public func contains(_ time: TimeInterval) -> Bool {
        range.contains(time)
    }

    /// 0 at the left edge, 1 at the right one; times outside the window fall outside 0...1.
    public func fraction(of time: TimeInterval) -> Double {
        span > 0 ? (time - start) / span : 0
    }

    public func time(atFraction fraction: Double) -> TimeInterval {
        start + fraction * span
    }

    // MARK: Changing

    /// Keeps `anchor` at the same place on screen; an anchor out of view is brought to the center.
    public mutating func setZoom(_ newZoom: Double, around anchor: TimeInterval) {
        guard duration > 0 else { return }
        let clampedZoom = min(max(newZoom, 1), maximumZoom)
        let visibleFraction = fraction(of: anchor)
        let anchorFraction = (0...1).contains(visibleFraction) ? visibleFraction : Self.centerFraction
        span = clampedZoom > 1 ? duration / clampedZoom : duration
        setStart(anchor - anchorFraction * span)
    }

    public mutating func zoom(by factor: Double, around anchor: TimeInterval) {
        guard factor > 0 else { return }
        setZoom(zoomLevel * factor, around: anchor)
    }

    public mutating func zoomIn(around anchor: TimeInterval) {
        zoom(by: Self.zoomStep, around: anchor)
    }

    public mutating func zoomOut(around anchor: TimeInterval) {
        zoom(by: 1 / Self.zoomStep, around: anchor)
    }

    public mutating func zoomToFit() {
        span = duration
        start = 0
    }

    public mutating func scroll(by offset: TimeInterval) {
        setStart(start + offset)
    }

    /// Pages forward when playback runs off the right edge; any other jump out of view centers the time.
    public mutating func reveal(_ time: TimeInterval) {
        guard !contains(time) else { return }
        if time > end && time < end + span {
            setStart(end)
        } else {
            setStart(time - Self.centerFraction * span)
        }
    }

    /// Follows the playhead only when it leaves the view, so scrolling away from it stays put.
    public mutating func follow(from oldTime: TimeInterval, to newTime: TimeInterval) {
        guard contains(oldTime), !contains(newTime) else { return }
        reveal(newTime)
    }

    private mutating func setStart(_ newStart: TimeInterval) {
        start = min(max(newStart, 0), max(0, duration - span))
    }
}
