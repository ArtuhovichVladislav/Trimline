import Foundation

struct MediaFile: Sendable {
    let url: URL
    let size: Int64
    let modified: Date?

    init(_ url: URL) throws(MediaOpenError) {
        let values: URLResourceValues
        do {
            values = try url.resourceValues(
                forKeys: [.fileSizeKey, .contentModificationDateKey, .isReadableKey, .isRegularFileKey]
            )
        } catch {
            throw .unreadable
        }
        guard values.isRegularFile == true, values.isReadable == true else { throw .unreadable }
        self.url = url
        size = Int64(values.fileSize ?? 0)
        modified = values.contentModificationDate
    }

    var waveformIdentity: WaveformCache.FileIdentity? {
        modified.map {
            WaveformCache.FileIdentity(path: url.standardizedFileURL.path, size: size, modificationDate: $0)
        }
    }

    // Uncompressed streams such as WAV report no bit rate; the file average is close enough for them.
    func averageBitRate(duration: TimeInterval) -> Double {
        guard duration > 0 else { return 0 }
        return Double(size) * Double(UInt8.bitWidth) / duration
    }
}
