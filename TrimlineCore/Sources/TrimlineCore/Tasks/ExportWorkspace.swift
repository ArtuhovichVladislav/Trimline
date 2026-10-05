import Darwin
import Foundation

// The clip is written next to its destination and renamed into place only when complete,
// so a half-written file never shows up under the final name.
struct ExportWorkspace: Sendable {
    static let diskSpaceMargin: Int64 = 16 * 1024 * 1024
    private static let fallbackFolderPrefix = ".trimline-export-"

    let destination: URL
    let directory: URL

    var fileURL: URL { directory.appendingPathComponent(destination.lastPathComponent) }

    static func prepare(for request: ExportRequest) throws(ExportError) -> ExportWorkspace {
        try checkDestination(request)
        let folder = request.destination.deletingLastPathComponent()
        return ExportWorkspace(destination: request.destination, directory: try makeDirectory(near: folder))
    }

    func publish() throws(ExportError) {
        // RENAME_EXCL makes the rename fail instead of replacing a file created in the meantime.
        guard renamex_np(fileURL.path, destination.path, UInt32(RENAME_EXCL)) != 0 else { return }
        let code = errno
        switch code {
        case EEXIST:
            throw .destinationExists
        case ENOTSUP, EINVAL:
            try moveWithoutReplacing()
        case EACCES, EPERM, EROFS:
            throw .destinationNotWritable
        default:
            throw .failed(String(cString: strerror(code)))
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }

    static func availableCapacity(of folder: URL) -> Int64? {
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey]
        guard let values = try? folder.resourceValues(forKeys: keys) else { return nil }
        if let important = values.volumeAvailableCapacityForImportantUsage, important > 0 {
            return important
        }
        return values.volumeAvailableCapacity.map(Int64.init)
    }

    // MARK: Private

    private func moveWithoutReplacing() throws(ExportError) {
        do {
            try FileManager.default.moveItem(at: fileURL, to: destination)
        } catch let error as CocoaError where error.code == .fileWriteFileExists {
            throw .destinationExists
        } catch {
            throw .failed(error.localizedDescription)
        }
    }

    private static func checkDestination(_ request: ExportRequest) throws(ExportError) {
        let fileManager = FileManager.default
        // Unlike `fileExists`, this also sees a dangling symbolic link.
        if (try? fileManager.attributesOfItem(atPath: request.destination.path)) != nil {
            throw .destinationExists
        }
        let folder = request.destination.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue,
            fileManager.isWritableFile(atPath: folder.path)
        else { throw .destinationNotWritable }

        let (sum, overflow) = max(0, request.estimatedSize).addingReportingOverflow(diskSpaceMargin)
        let required = overflow ? Int64.max : sum
        if let available = availableCapacity(of: folder), available < required {
            throw .insufficientDiskSpace(required: required, available: available)
        }
    }

    private static func makeDirectory(near folder: URL) throws(ExportError) -> URL {
        let fileManager = FileManager.default
        if let directory = try? fileManager.url(
            for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: folder, create: true
        ) {
            if isOnSameVolume(directory, folder) {
                return directory
            }
            try? fileManager.removeItem(at: directory)
        }
        // Some volumes have no replacement folder; a hidden sibling keeps the final rename atomic.
        let fallback = folder.appendingPathComponent(fallbackFolderPrefix + UUID().uuidString, isDirectory: true)
        do {
            try fileManager.createDirectory(at: fallback, withIntermediateDirectories: false)
        } catch {
            throw .destinationNotWritable
        }
        return fallback
    }

    private static func isOnSameVolume(_ first: URL, _ second: URL) -> Bool {
        let key: Set<URLResourceKey> = [.volumeIdentifierKey]
        guard let a = try? first.resourceValues(forKeys: key).volumeIdentifier,
            let b = try? second.resourceValues(forKeys: key).volumeIdentifier
        else { return false }
        return a.isEqual(b)
    }
}
