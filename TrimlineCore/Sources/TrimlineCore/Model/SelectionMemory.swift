import Foundation

/// Keeps the clip bounds of recently edited files so reopening one brings its selection back.
public protocol SelectionMemory: Sendable {
    func selection(for file: FileFingerprint) async -> ClosedRange<TimeInterval>?
    func remember(_ range: ClosedRange<TimeInterval>, for file: FileFingerprint) async
    func forget(_ file: FileFingerprint) async
    func forgetAll() async
}

/// A file counts as the same when its name, size and modification time match. The folder is left out,
/// so a moved file (Open Recent follows moves) keeps its selection; editing or replacing it changes the
/// size or the time.
public struct FileFingerprint: Sendable, Hashable, Codable {
    public let name: String
    public let size: Int64
    // Whole microseconds, so the value survives a JSON round trip exactly.
    public let modified: Int64

    public init(name: String, size: Int64, modificationDate: Date) {
        self.name = name
        self.size = size
        self.modified = Int64((modificationDate.timeIntervalSince1970 * 1_000_000).rounded())
    }

    // Reads the attributes afresh: URL resource values may be cached from an earlier open.
    public init?(of url: URL) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
            let size = attributes[.size] as? NSNumber,
            let date = attributes[.modificationDate] as? Date
        else { return nil }
        self.init(name: url.lastPathComponent, size: size.int64Value, modificationDate: date)
    }
}
