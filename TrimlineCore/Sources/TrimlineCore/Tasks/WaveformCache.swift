import CryptoKit
import Foundation

// Not an actor itself: only the waveform builders (WaveformBuilder, FFmpegWaveformBuilder) call it, and they
// already keep disk work off the main actor.
struct WaveformCache: Sendable {
    struct FileIdentity: Sendable, Hashable {
        let path: String
        let size: Int64
        let modificationDate: Date
    }

    static let defaultSizeLimit: Int64 = 100 * 1024 * 1024
    private static let fileExtension = "peaks"
    private static let bytesPerPeak = 2 * MemoryLayout<Float>.size

    let directory: URL
    let sizeLimit: Int64

    init(directory: URL = WaveformCache.defaultDirectory, sizeLimit: Int64 = WaveformCache.defaultSizeLimit) {
        self.directory = directory
        self.sizeLimit = sizeLimit
    }

    static var defaultDirectory: URL {
        let caches =
            FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return
            caches
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "Trimline", isDirectory: true)
            .appendingPathComponent("waveforms", isDirectory: true)
    }

    func peaks(for file: FileIdentity, buckets: Int) -> [Peak]? {
        let url = entryURL(for: file, buckets: buckets)
        guard let data = try? Data(contentsOf: url), data.count == buckets * Self.bytesPerPeak else { return nil }
        // Touching the entry turns "evict oldest" into least recently used.
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return Self.decode(data)
    }

    func store(_ peaks: [Peak], for file: FileIdentity) {
        let url = entryURL(for: file, buckets: peaks.count)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Self.encode(peaks).write(to: url, options: .atomic)
        } catch {
            return
        }
        evictIfNeeded()
    }

    func entryURL(for file: FileIdentity, buckets: Int) -> URL {
        let key = "\(file.path)\n\(file.size)\n\(file.modificationDate.timeIntervalSinceReferenceDate)\n\(buckets)"
        let hash = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(hash).appendingPathExtension(Self.fileExtension)
    }

    // MARK: Private

    private struct Entry {
        let url: URL
        let size: Int64
        let date: Date
    }

    private func evictIfNeeded() {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)
        else { return }
        let entries = urls.compactMap { url -> Entry? in
            guard url.pathExtension == Self.fileExtension,
                let values = try? url.resourceValues(forKeys: Set(keys))
            else { return nil }
            return Entry(
                url: url, size: Int64(values.fileSize ?? 0), date: values.contentModificationDate ?? .distantPast)
        }
        var total = entries.reduce(0) { $0 + $1.size }
        for entry in entries.sorted(by: { $0.date < $1.date }) where total > sizeLimit {
            try? FileManager.default.removeItem(at: entry.url)
            total -= entry.size
        }
    }

    private static func encode(_ peaks: [Peak]) -> Data {
        let values = peaks.flatMap { [$0.min, $0.max] }
        return values.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    private static func decode(_ data: Data) -> [Peak] {
        data.withUnsafeBytes { raw in
            stride(from: 0, to: raw.count, by: bytesPerPeak).map { offset in
                Peak(
                    min: raw.loadUnaligned(fromByteOffset: offset, as: Float.self),
                    max: raw.loadUnaligned(fromByteOffset: offset + MemoryLayout<Float>.size, as: Float.self)
                )
            }
        }
    }
}
