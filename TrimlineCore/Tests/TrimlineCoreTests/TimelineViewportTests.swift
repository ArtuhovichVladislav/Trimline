import Foundation
import Testing

@testable import TrimlineCore

@Suite struct TimelineViewportTests {
    private static let tolerance = 1e-9

    private func isClose(_ lhs: Double, _ rhs: Double) -> Bool {
        abs(lhs - rhs) < Self.tolerance
    }

    @Test func startsShowingWholeFile() {
        let viewport = TimelineViewport(duration: 100)
        #expect(viewport.range == 0...100)
        #expect(viewport.zoomLevel == 1)
        #expect(!viewport.isZoomed)
        #expect(viewport.canZoomIn)
        #expect(!viewport.canZoomOut)
    }

    @Test func zoomKeepsAnchorInPlace() {
        var viewport = TimelineViewport(duration: 100)
        viewport.zoom(by: 4, around: 30)
        #expect(isClose(viewport.span, 25))
        #expect(isClose(viewport.fraction(of: 30), 0.3))
        viewport.zoom(by: 2, around: 35)
        #expect(isClose(viewport.span, 12.5))
        #expect(isClose(viewport.fraction(of: 35), (35 - 22.5) / 25))
    }

    @Test func zoomOutReturnsToWholeFile() {
        var viewport = TimelineViewport(duration: 100)
        viewport.zoomIn(around: 70)
        viewport.zoomOut(around: 70)
        #expect(viewport.range == 0...100)
        #expect(!viewport.isZoomed)
        viewport.zoomOut(around: 70)
        #expect(viewport.range == 0...100)
    }

    @Test func zoomStopsAtOneSecondSpan() {
        var viewport = TimelineViewport(duration: 100)
        viewport.setZoom(1_000, around: 50)
        #expect(isClose(viewport.span, TimelineViewport.minimumSpan))
        #expect(!viewport.canZoomIn)
        #expect(viewport.canZoomOut)
    }

    @Test func zoomIsCappedForVeryLongFiles() {
        var viewport = TimelineViewport(duration: 100_000)
        viewport.setZoom(.infinity, around: 0)
        #expect(viewport.zoomLevel == TimelineViewport.zoomLimit)
        #expect(isClose(viewport.span, 10))
    }

    @Test func shortFilesDoNotZoom() {
        var viewport = TimelineViewport(duration: 0.5)
        #expect(!viewport.canZoomIn)
        viewport.zoomIn(around: 0.25)
        #expect(viewport.range == 0...0.5)

        var empty = TimelineViewport(duration: 0)
        empty.zoomIn(around: 0)
        #expect(empty.range == 0...0)
        #expect(empty.fraction(of: 5) == 0)
    }

    @Test func zoomNearEdgesStaysInsideFile() {
        var viewport = TimelineViewport(duration: 100)
        viewport.zoom(by: 10, around: 0)
        #expect(viewport.start == 0)
        viewport.zoomToFit()
        viewport.zoom(by: 10, around: 100)
        #expect(isClose(viewport.end, 100))
    }

    @Test func anchorOutOfViewIsCentered() {
        var viewport = TimelineViewport(duration: 100)
        viewport.zoom(by: 10, around: 0)
        viewport.zoomIn(around: 60)
        #expect(isClose(viewport.span, 5))
        #expect(isClose(viewport.start, 57.5))
    }

    @Test func scrollIsClampedToFile() {
        var viewport = TimelineViewport(duration: 100)
        viewport.scroll(by: 10)
        #expect(viewport.start == 0)
        viewport.zoom(by: 4, around: 0)
        viewport.scroll(by: 10)
        #expect(viewport.range == 10...35)
        viewport.scroll(by: 1_000)
        #expect(viewport.range == 75...100)
        viewport.scroll(by: -1_000)
        #expect(viewport.range == 0...25)
    }

    @Test func revealPagesForwardAndCentersJumps() {
        var viewport = TimelineViewport(duration: 100)
        viewport.zoom(by: 10, around: 0)
        viewport.reveal(5)
        #expect(viewport.start == 0)
        viewport.reveal(10.5)
        #expect(viewport.range == 10...20)
        viewport.reveal(60)
        #expect(viewport.range == 55...65)
        viewport.reveal(1)
        #expect(viewport.range == 0...10)
        viewport.reveal(99.9)
        #expect(isClose(viewport.end, 100))
    }

    @Test func followsPlayheadOnlyWhenItLeavesTheView() {
        var viewport = TimelineViewport(duration: 100)
        viewport.zoom(by: 10, around: 0)
        viewport.follow(from: 9.9, to: 10.1)
        #expect(viewport.range == 10...20)
        viewport.scroll(by: 50)
        viewport.follow(from: 10.2, to: 10.3)
        #expect(viewport.range == 60...70)
    }
}
