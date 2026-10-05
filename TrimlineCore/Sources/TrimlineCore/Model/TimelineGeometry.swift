import CoreGraphics
import Foundation

/// Maps between times and x positions for the visible window. The track is inset by one handle width
/// on each side, so the yellow handles sit outside the selected range and never cover the frames inside it.
public struct TimelineGeometry: Sendable {
    public enum Target: Equatable, Sendable {
        case handle(EditorModel.TrimHandle)
        case playhead
        case selection
        case track
    }

    // Extra grab area beyond the drawn handle, for a forgiving click target.
    private static let handleSlop: CGFloat = 4
    // The playhead line is 2 pt wide; grab it a few points either side.
    private static let playheadGrabRadius: CGFloat = 5
    // Positions far off screen are pulled in to just past the edge, so nothing huge is laid out.
    private static let drawingOverscan: CGFloat = 40
    // Dragging this close to a track edge, or past it, scrolls the zoomed timeline.
    public static let autoScrollZone: CGFloat = 24
    public static let autoScrollSpeed: CGFloat = 500
    private static let autoScrollMaximumRate: CGFloat = 3

    public let width: CGFloat
    public let handleWidth: CGFloat
    public let viewport: TimelineViewport

    public init(width: CGFloat, handleWidth: CGFloat, viewport: TimelineViewport) {
        self.width = width
        self.handleWidth = handleWidth
        self.viewport = viewport
    }

    public var trackWidth: CGFloat { max(0, width - 2 * handleWidth) }

    public var secondsPerPoint: TimeInterval {
        trackWidth > 0 ? viewport.span / TimeInterval(trackWidth) : 0
    }

    /// Unclamped: times outside the visible window land outside the track.
    public func x(for time: TimeInterval) -> CGFloat {
        handleWidth + trackX(for: time)
    }

    public func trackX(for time: TimeInterval) -> CGFloat {
        CGFloat(viewport.fraction(of: time)) * trackWidth
    }

    public func visibleTrackX(for time: TimeInterval) -> CGFloat {
        min(max(trackX(for: time), 0), trackWidth)
    }

    public func drawingX(for time: TimeInterval) -> CGFloat {
        min(max(x(for: time), -Self.drawingOverscan), width + Self.drawingOverscan)
    }

    /// Unclamped, for drag offsets that must not jump when grabbed off the track.
    public func time(at x: CGFloat) -> TimeInterval {
        guard trackWidth > 0 else { return viewport.start }
        return viewport.time(atFraction: TimeInterval((x - handleWidth) / trackWidth))
    }

    public func visibleTime(at x: CGFloat) -> TimeInterval {
        min(max(time(at: x), viewport.start), viewport.end)
    }

    public func target(at x: CGFloat, selection: Selection, playhead: TimeInterval) -> Target {
        let startX = self.x(for: selection.start)
        let endX = self.x(for: selection.end)
        if x >= startX - handleWidth - Self.handleSlop && x <= startX {
            return .handle(.start)
        }
        if x >= endX && x <= endX + handleWidth + Self.handleSlop {
            return .handle(.end)
        }
        if abs(x - self.x(for: playhead)) <= Self.playheadGrabRadius {
            return .playhead
        }
        if x > startX && x < endX {
            return .selection
        }
        return .track
    }

    /// Points per second, negative towards the start; zero away from the edges or when there is nowhere to go.
    public func autoScrollVelocity(at x: CGFloat) -> CGFloat {
        guard viewport.isZoomed else { return 0 }
        let leftDepth = handleWidth + Self.autoScrollZone - x
        let rightDepth = x - (width - handleWidth - Self.autoScrollZone)
        if leftDepth > 0, viewport.start > 0 {
            return -Self.autoScrollSpeed * min(leftDepth / Self.autoScrollZone, Self.autoScrollMaximumRate)
        }
        if rightDepth > 0, viewport.end < viewport.duration {
            return Self.autoScrollSpeed * min(rightDepth / Self.autoScrollZone, Self.autoScrollMaximumRate)
        }
        return 0
    }
}
