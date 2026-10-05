import Foundation
import Testing

@testable import TrimlineCore

@Suite struct SelectionStoreTests {
    private let fileURL: URL

    init() throws {
        fileURL = try TestMedia.makeTemporaryFolder().appendingPathComponent("Support/Selections.json")
    }

    @Test func selectionsSurviveRelaunch() async throws {
        let store = SelectionStore(fileURL: fileURL)
        await store.remember(1.0 / 3...7.25, for: file("a"))
        await store.remember(2...4, for: file("b"))
        await store.forget(file("b"))

        let relaunched = SelectionStore(fileURL: fileURL)
        #expect(await relaunched.selection(for: file("a")) == 1.0 / 3...7.25)
        #expect(await relaunched.selection(for: file("b")) == nil)
    }

    @Test func sizeOrTimeChangeIsAnotherFile() async {
        let store = SelectionStore(fileURL: fileURL)
        await store.remember(1...2, for: file("a"))
        #expect(await store.selection(for: file("a", size: 2)) == nil)
        #expect(await store.selection(for: file("a", date: Date(timeIntervalSince1970: 1))) == nil)
        #expect(await store.selection(for: file("b")) == nil)
    }

    @Test func keepsMostRecentlyUsedFiles() async {
        let store = SelectionStore(fileURL: fileURL, limit: 3)
        for name in ["a", "b", "c"] {
            await store.remember(1...2, for: file(name))
        }
        await store.remember(1...3, for: file("a"))
        await store.remember(1...2, for: file("d"))

        let relaunched = SelectionStore(fileURL: fileURL, limit: 3)
        #expect(await relaunched.selection(for: file("a")) == 1...3)
        #expect(await relaunched.selection(for: file("b")) == nil)
        #expect(await relaunched.selection(for: file("c")) == 1...2)
        #expect(await relaunched.selection(for: file("d")) == 1...2)
    }

    @Test func forgettingAllRemovesTheFile() async {
        let store = SelectionStore(fileURL: fileURL)
        await store.remember(1...2, for: file("a"))
        await store.forgetAll()
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
        #expect(await store.selection(for: file("a")) == nil)
    }

    @Test func unreadableFileStartsEmpty() async throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: fileURL)
        let store = SelectionStore(fileURL: fileURL)
        #expect(await store.selection(for: file("a")) == nil)
        await store.remember(1...2, for: file("a"))
        #expect(await SelectionStore(fileURL: fileURL).selection(for: file("a")) == 1...2)
    }

    @Test func fingerprintFollowsEdits() throws {
        let url = try TestMedia.makeTemporaryFolder().appendingPathComponent("clip.mp4")
        try Data(repeating: 0, count: 100).write(to: url)
        let original = try #require(FileFingerprint(of: url))
        #expect(original.name == "clip.mp4")
        #expect(original.size == 100)
        #expect(FileFingerprint(of: url) == original)

        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -60)], ofItemAtPath: url.path)
        #expect(FileFingerprint(of: url) != original)
        #expect(FileFingerprint(of: url.appendingPathExtension("missing")) == nil)
    }

    private func file(_ name: String, size: Int64 = 1, date: Date = Date(timeIntervalSince1970: 1_700_000_000.123456))
        -> FileFingerprint
    {
        FileFingerprint(name: "\(name).mov", size: size, modificationDate: date)
    }
}
