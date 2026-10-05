import CoreGraphics
import Foundation
import Testing

@testable import TrimlineCore

@Suite struct TimelineGeometryTests {
    private static let handleWidth: CGFloat = 14
    // A 100 s file on a 200 pt track: 0.5 s per point at zoom 1.
    private static let width: CGFloat = 228

    private func geometry(zoom: Double = 1, around anchor: TimeInterval = 0) -> TimelineGeometry {
        var viewport = TimelineViewport(duration: 100)
        viewport.setZoom(zoom, around: anchor)
        return TimelineGeometry(width: Self.width, handleWidth: Self.handleWidth, viewport: viewport)
    }

    @Test func mapsWholeFileOntoTrack() {
        let geometry = geometry()
        #expect(geometry.trackWidth == 200)
        #expect(geometry.x(for: 0) == 14)
        #expect(geometry.x(for: 100) == 214)
        #expect(geometry.time(at: 114) == 50)
        #expect(geometry.secondsPerPoint == 0.5)
    }

    @Test func mapsVisibleWindowWhenZoomed() {
        let geometry = geometry(zoom: 4, around: 50)
        #expect(geometry.viewport.range == 37.5...62.5)
        #expect(geometry.x(for: 37.5) == 14)
        #expect(geometry.x(for: 62.5) == 214)
        #expect(geometry.time(at: 114) == 50)
        #expect(geometry.secondsPerPoint == 0.125)
    }

    @Test func positionsOutsideWindowAreUnclampedButDrawnNearEdges() {
        let geometry = geometry(zoom: 4, around: 50)
        #expect(geometry.x(for: 0) == -286)
        #expect(geometry.time(at: 0) < 37.5)
        #expect(geometry.visibleTime(at: 0) == 37.5)
        #expect(geometry.visibleTime(at: Self.width) == 62.5)
        #expect(geometry.drawingX(for: 0) < 0)
        #expect(geometry.drawingX(for: 0) > -100)
        #expect(geometry.drawingX(for: 100) > Self.width)
        #expect(geometry.drawingX(for: 100) < Self.width + 100)
        #expect(geometry.drawingX(for: 50) == geometry.x(for: 50))
        #expect(geometry.visibleTrackX(for: 0) == 0)
        #expect(geometry.visibleTrackX(for: 50) == 100)
        #expect(geometry.visibleTrackX(for: 100) == geometry.trackWidth)
    }

    @Test func hitTestsHandlesAndSelection() {
        let geometry = geometry()
        let selection = Selection(duration: 100, start: 20, end: 60)
        #expect(geometry.target(at: 50, selection: selection, playhead: 0) == .handle(.start))
        #expect(geometry.target(at: 140, selection: selection, playhead: 0) == .handle(.end))
        #expect(geometry.target(at: 80, selection: selection, playhead: 0) == .selection)
        #expect(geometry.target(at: 80, selection: selection, playhead: 33) == .playhead)
        #expect(geometry.target(at: 200, selection: selection, playhead: 0) == .track)
    }

    @Test func hitTestsAtZoomWithHandlesOffScreen() {
        let geometry = geometry(zoom: 10, around: 40)
        let selection = Selection(duration: 100, start: 20, end: 60)
        for x in stride(from: CGFloat(0), through: Self.width, by: 10) {
            #expect(geometry.target(at: x, selection: selection, playhead: 0) == .selection)
        }
        let edge = Selection(duration: 100, start: 40, end: 90)
        #expect(geometry.target(at: geometry.x(for: 40) - 5, selection: edge, playhead: 0) == .handle(.start))
    }

    @Test func autoScrollsOnlyNearEdgesWhenZoomed() {
        #expect(geometry().autoScrollVelocity(at: 0) == 0)
        let zoomed = geometry(zoom: 4, around: 50)
        #expect(zoomed.autoScrollVelocity(at: 114) == 0)
        #expect(zoomed.autoScrollVelocity(at: 20) < 0)
        #expect(zoomed.autoScrollVelocity(at: 220) > 0)
        #expect(zoomed.autoScrollVelocity(at: -1_000) == -TimelineGeometry.autoScrollSpeed * 3)
        #expect(zoomed.autoScrollVelocity(at: 210) < zoomed.autoScrollVelocity(at: 228))
    }

    @Test func doesNotAutoScrollPastFileEdges() {
        let atStart = geometry(zoom: 4, around: 0)
        #expect(atStart.autoScrollVelocity(at: 0) == 0)
        #expect(atStart.autoScrollVelocity(at: Self.width) > 0)
        let atEnd = geometry(zoom: 4, around: 100)
        #expect(atEnd.autoScrollVelocity(at: Self.width) == 0)
    }
}
