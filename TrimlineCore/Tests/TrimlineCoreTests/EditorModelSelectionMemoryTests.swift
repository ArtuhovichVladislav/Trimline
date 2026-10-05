import Foundation
import Testing

@testable import TrimlineCore

@MainActor
@Suite struct EditorModelSelectionMemoryTests {
    private let folder: URL
    private let memory = FakeSelectionMemory()

    init() throws {
        folder = try TestMedia.makeTemporaryFolder()
    }

    @Test func reopenedFileGetsItsSelectionBack() async throws {
        let (model, movie) = try makeModel()
        try await open(movie, in: model)
        model.setHandle(.start, to: 2)
        model.setHandle(.end, to: 5)
        try await open(try makeFile("other.mkv"), in: model)

        var changes: [SelectionHistory.Change] = []
        model.onHistoryChange = { changes.append($0) }
        try await open(movie, in: model)
        #expect(model.selection.range == 2...5)
        #expect(model.currentTime == 2)
        #expect(player(of: model)?.seeks.last == FakePlayback.Seek(time: 2, precise: true))
        #expect(!model.canUndo)
        #expect(changes == [.cleared])
    }

    @Test func changedFileStartsWithWholeSelection() async throws {
        let (model, movie) = try makeModel()
        try await open(movie, in: model)
        model.setHandle(.end, to: 5)
        try await open(try makeFile("other.mkv"), in: model)

        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -60)], ofItemAtPath: movie.path)
        try await open(movie, in: model)
        #expect(model.selection.coversWholeFile)

        model.setHandle(.end, to: 5)
        try await open(try makeFile("other.mkv"), in: model)
        try Data(repeating: 1, count: 2048).write(to: movie)
        try await open(movie, in: model)
        #expect(model.selection.coversWholeFile)
    }

    @Test func movedFileKeepsItsSelection() async throws {
        let (model, movie) = try makeModel()
        try await open(movie, in: model)
        model.setHandle(.start, to: 3)
        try await open(try makeFile("other.mkv"), in: model)

        let moved = try TestMedia.makeTemporaryFolder().appendingPathComponent(movie.lastPathComponent)
        try FileManager.default.moveItem(at: movie, to: moved)
        try await open(moved, in: model)
        #expect(model.selection.start == 3)
    }

    @Test func wholeFileIsNotStoredAndResetForgets() async throws {
        let (model, movie) = try makeModel()
        try await open(movie, in: model)
        try await open(try makeFile("other.mkv"), in: model)
        #expect(await memory.rememberCount == 0)
        #expect(await memory.isEmpty)

        try await open(movie, in: model)
        model.setHandle(.start, to: 1)
        await model.rememberSelectionNow()
        #expect(await !memory.isEmpty)

        model.resetSelection()
        try await open(try makeFile("other.mkv"), in: model)
        #expect(await memory.isEmpty)
        try await open(movie, in: model)
        #expect(model.selection.coversWholeFile)
    }

    @Test func restoredSelectionIsClampedToDuration() async throws {
        let movie = try makeFile("movie.mkv")
        let file = try #require(FileFingerprint(of: movie))
        await memory.remember(2...9, for: file)
        let (model, _) = try makeModel(duration: 6)
        try await open(movie, in: model)
        #expect(model.selection.range == 2...6)
    }

    @Test func selectionPastTheEndIsIgnored() async throws {
        let movie = try makeFile("movie.mkv")
        let file = try #require(FileFingerprint(of: movie))
        await memory.remember(7...9, for: file)
        let (model, _) = try makeModel(duration: 6)
        try await open(movie, in: model)
        #expect(model.selection.coversWholeFile)
    }

    // A typed start between key frames stays exact in fast mode, so it comes back unsnapped.
    @Test func restoredStartIsNotSnapped() async throws {
        let movie = try makeFile("movie.mkv")
        await memory.remember(3.3...5, for: try #require(FileFingerprint(of: movie)))
        let (model, _) = try makeModel()
        try await open(movie, in: model)
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.selection.start == 3.3)
    }

    @Test func dragIsWrittenOnceAfterItSettles() async throws {
        let (model, movie) = try makeModel()
        try await open(movie, in: model)
        model.beginDragging(.end)
        for end in [9.0, 8, 7, 6] {
            model.drag(.end, to: end)
        }
        model.endDragging(.end)
        #expect(await memory.rememberCount == 0)

        #expect(await waitUntilRemembered(count: 1))
        let file = try #require(FileFingerprint(of: movie))
        #expect(await memory.selection(for: file) == 0...6)
        try await Task.sleep(for: SelectionRecall.writeDelay + .milliseconds(200))
        #expect(await memory.rememberCount == 1)
    }

    @Test func quittingRightAfterDragWritesSelection() async throws {
        let (model, movie) = try makeModel()
        try await open(movie, in: model)
        model.beginDragging(.end)
        model.drag(.end, to: 4)
        model.endDragging(.end)
        await model.rememberSelectionNow()
        #expect(await memory.selection(for: try #require(FileFingerprint(of: movie))) == 0...4)
    }

    @Test func forgettingAllStopsRememberingOpenFile() async throws {
        let (model, movie) = try makeModel()
        try await open(movie, in: model)
        model.setHandle(.end, to: 4)
        await model.rememberSelectionNow()

        model.forgetRememberedSelections()
        model.setHandle(.end, to: 3)
        await model.rememberSelectionNow()
        #expect(await memory.isEmpty)
    }

    // MARK: Helpers

    private func makeFile(_ name: String) throws -> URL {
        let url = folder.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: url.path) {
            try Data(repeating: 0, count: 1024).write(to: url)
        }
        return url
    }

    private func makeModel(duration: TimeInterval = 10) throws -> (EditorModel, URL) {
        let model = EditorModel(
            clipSuffix: "clip",
            opener: { url throws(MediaOpenError) in await FakeEngine.video(url: url, duration: duration) },
            selectionMemory: memory
        )
        return (model, try makeFile("movie.mkv"))
    }

    private func open(_ url: URL, in model: EditorModel) async throws {
        model.open(url)
        try #require(await waitUntil { model.phase == .ready && model.info?.url == url })
    }

    private func player(of model: EditorModel) -> FakePlayback? {
        model.playback as? FakePlayback
    }

    private func waitUntilRemembered(count: Int) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while await memory.rememberCount < count {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }
}

actor FakeSelectionMemory: SelectionMemory {
    private var ranges: [FileFingerprint: ClosedRange<TimeInterval>] = [:]
    private(set) var rememberCount = 0

    var isEmpty: Bool { ranges.isEmpty }

    func selection(for file: FileFingerprint) -> ClosedRange<TimeInterval>? {
        ranges[file]
    }

    func remember(_ range: ClosedRange<TimeInterval>, for file: FileFingerprint) {
        ranges[file] = range
        rememberCount += 1
    }

    func forget(_ file: FileFingerprint) {
        ranges[file] = nil
    }

    func forgetAll() {
        ranges.removeAll()
    }
}
