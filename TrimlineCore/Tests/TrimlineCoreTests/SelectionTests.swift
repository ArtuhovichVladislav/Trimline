import Foundation
import Testing

@testable import TrimlineCore

@Suite struct SelectionTests {
    @Test func startsCoveringWholeFile() {
        let selection = Selection(duration: 10)
        #expect(selection.range == 0...10)
        #expect(selection.coversWholeFile)
    }

    @Test func keepsMinimumLength() {
        var selection = Selection(duration: 10, start: 4, end: 6)
        selection.setStart(5.99)
        #expect(selection.start == 6 - Selection.minimumLength)
        selection.setEnd(0)
        #expect(selection.end == selection.start + Selection.minimumLength)
        #expect(abs(selection.length - Selection.minimumLength) < 1e-9)
    }

    @Test func handlesNeverCross() {
        var selection = Selection(duration: 10, start: 3, end: 5)
        selection.setStart(8)
        #expect(selection.start < selection.end)
        selection.setEnd(1)
        #expect(selection.end > selection.start)
    }

    @Test func clampsToFile() {
        var selection = Selection(duration: 10)
        selection.setStart(-3)
        selection.setEnd(42)
        #expect(selection.range == 0...10)

        let initial = Selection(duration: 10, start: -1, end: 11)
        #expect(initial.coversWholeFile)
    }

    @Test func negativeDurationBecomesEmpty() {
        let selection = Selection(duration: -5)
        #expect(selection.duration == 0)
        #expect(selection.range == 0...0)
    }

    @Test func moveKeepsLength() {
        var selection = Selection(duration: 10, start: 2, end: 5)
        selection.move(by: 1.5)
        #expect(selection.range == 3.5...6.5)
        #expect(selection.length == 3)
    }

    @Test func moveStopsAtEdges() {
        var selection = Selection(duration: 10, start: 2, end: 5)
        selection.move(by: 100)
        #expect(selection.range == 7...10)
        selection.move(by: -100)
        #expect(selection.range == 0...3)
    }

    @Test func veryShortFileStillSelectsEverything() {
        var selection = Selection(duration: 0.05)
        #expect(selection.range == 0...0.05)
        selection.setStart(0.03)
        #expect(selection.start == 0)
        selection.setEnd(0.01)
        #expect(selection.end == 0.05)
        selection.move(by: 1)
        #expect(selection.range == 0...0.05)
    }

    @Test func resetRestoresWholeFile() {
        var selection = Selection(duration: 10, start: 2, end: 3)
        #expect(!selection.coversWholeFile)
        selection.reset()
        #expect(selection.coversWholeFile)
    }
}
