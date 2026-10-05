import Foundation
import Testing

@testable import TrimlineCore

@Suite struct WaveformCacheTests {
    private let peaks = (0..<100).map { Peak(min: -Float($0) / 100, max: Float($0) / 100) }

    @Test func roundTripsPeaks() throws {
        let cache = WaveformCache(directory: try TestMedia.makeTemporaryFolder())
        let file = identity("a")
        #expect(cache.peaks(for: file, buckets: peaks.count) == nil)

        cache.store(peaks, for: file)
        #expect(cache.peaks(for: file, buckets: peaks.count) == peaks)
        #expect(cache.peaks(for: file, buckets: 50) == nil)
    }

    @Test func keyDependsOnSizeAndDate() throws {
        let cache = WaveformCache(directory: try TestMedia.makeTemporaryFolder())
        cache.store(peaks, for: identity("a"))
        #expect(cache.peaks(for: identity("a", size: 2), buckets: peaks.count) == nil)
        #expect(cache.peaks(for: identity("a", date: Date(timeIntervalSince1970: 1)), buckets: peaks.count) == nil)
        #expect(cache.peaks(for: identity("b"), buckets: peaks.count) == nil)
    }

    @Test func evictsOldestEntriesOverLimit() throws {
        let entrySize = Int64(peaks.count * 2 * MemoryLayout<Float>.size)
        let cache = WaveformCache(directory: try TestMedia.makeTemporaryFolder(), sizeLimit: entrySize * 2)
        let names = ["first", "second", "third"]
        for (age, name) in zip([300.0, 200, 100], names) {
            cache.store(peaks, for: identity(name))
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSinceNow: -age)],
                ofItemAtPath: cache.entryURL(for: identity(name), buckets: peaks.count).path
            )
        }

        let remaining = try FileManager.default.contentsOfDirectory(atPath: cache.directory.path)
        #expect(remaining.count == 2)
        #expect(
            !FileManager.default.fileExists(atPath: cache.entryURL(for: identity("first"), buckets: peaks.count).path))
        #expect(cache.peaks(for: identity("third"), buckets: peaks.count) == peaks)
    }

    private func identity(_ name: String, size: Int64 = 1, date: Date = Date(timeIntervalSince1970: 0))
        -> WaveformCache.FileIdentity
    {
        WaveformCache.FileIdentity(path: "/tmp/\(name).mp3", size: size, modificationDate: date)
    }
}
