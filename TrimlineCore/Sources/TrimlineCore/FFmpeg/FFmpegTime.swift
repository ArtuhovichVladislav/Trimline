import CoreMedia
import Foundation
import libavutil

enum FFmpegTime {
    // AV_NOPTS_VALUE and AV_TIME_BASE are cast-based macros that Swift doesn't import.
    static let noValue = Int64.min
    static let microsecondsPerSecond: Int64 = 1_000_000

    static func seconds(_ value: Int64, in timeBase: AVRational) -> TimeInterval? {
        guard value != noValue, timeBase.den != 0 else { return nil }
        return Double(value) * Double(timeBase.num) / Double(timeBase.den)
    }

    /// Saturates instead of trapping: times derived from a malformed file can be far outside Int64.
    static func timestamp(_ seconds: TimeInterval, in timeBase: AVRational) -> Int64 {
        guard timeBase.num != 0 else { return 0 }
        let value = seconds * Double(timeBase.den) / Double(timeBase.num)
        if let rounded = rounded(value) { return max(rounded, -Int64.max) }
        return value.isNaN ? 0 : (value > 0 ? .max : -Int64.max)
    }

    static func cmTime(_ value: Int64, in timeBase: AVRational) -> CMTime {
        guard value != noValue, timeBase.den != 0 else { return .invalid }
        let (scaled, overflows) = value.multipliedReportingOverflow(by: Int64(timeBase.num))
        return overflows ? .invalid : CMTime(value: scaled, timescale: timeBase.den)
    }

    /// `nil` for NaN, infinities and values outside Int64.
    static func rounded(_ value: Double) -> Int64? {
        Int64(exactly: value.rounded())
    }

    // Timestamp arithmetic on values read from a file: an overflow means the file is malformed.

    static func sum(_ value: Int64, _ other: Int64) throws(FFmpegError) -> Int64 {
        let (result, overflows) = value.addingReportingOverflow(other)
        guard !overflows else { throw .invalidData }
        return result
    }

    static func difference(_ value: Int64, _ other: Int64) throws(FFmpegError) -> Int64 {
        let (result, overflows) = value.subtractingReportingOverflow(other)
        guard !overflows else { throw .invalidData }
        return result
    }
}
