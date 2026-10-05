import Foundation

/// The app's `SelectionMemory`: a small JSON file in Application Support with the most recently used
/// files first. Loaded on first use and rewritten only when an entry actually changes.
public actor SelectionStore: SelectionMemory {
    struct Entry: Codable, Equatable {
        let file: FileFingerprint
        let start: TimeInterval
        let end: TimeInterval
    }

    public static let defaultLimit = 100

    public let fileURL: URL
    public let limit: Int
    private var loadedEntries: [Entry]?

    public init(fileURL: URL = SelectionStore.defaultFileURL, limit: Int = SelectionStore.defaultLimit) {
        self.fileURL = fileURL
        self.limit = max(1, limit)
    }

    public static var defaultFileURL: URL {
        let support =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return
            support
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "Trimline", isDirectory: true)
            .appendingPathComponent("Selections.json")
    }

    public func selection(for file: FileFingerprint) -> ClosedRange<TimeInterval>? {
        guard let entry = entries.first(where: { $0.file == file }), entry.start < entry.end else { return nil }
        return entry.start...entry.end
    }

    public func remember(_ range: ClosedRange<TimeInterval>, for file: FileFingerprint) {
        let entry = Entry(file: file, start: range.lowerBound, end: range.upperBound)
        guard entries.first != entry else { return }
        var updated = entries.filter { $0.file != file }
        updated.insert(entry, at: 0)
        save(Array(updated.prefix(limit)))
    }

    public func forget(_ file: FileFingerprint) {
        guard entries.contains(where: { $0.file == file }) else { return }
        save(entries.filter { $0.file != file })
    }

    public func forgetAll() {
        loadedEntries = []
        try? FileManager.default.removeItem(at: fileURL)
    }

    // MARK: Private

    private var entries: [Entry] {
        if let loadedEntries { return loadedEntries }
        let loaded = (try? Data(contentsOf: fileURL)).flatMap { try? JSONDecoder().decode([Entry].self, from: $0) }
        loadedEntries = loaded ?? []
        return loadedEntries ?? []
    }

    private func save(_ updated: [Entry]) {
        loadedEntries = updated
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(updated).write(to: fileURL, options: .atomic)
        } catch {
            return
        }
    }
}
