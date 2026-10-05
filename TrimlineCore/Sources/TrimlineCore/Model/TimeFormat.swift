import Foundation

public struct TimeFormat: Sendable {
    public static let hoursThreshold: TimeInterval = 3600

    private let showsHours: Bool
    private let decimalSeparator: String

    public init(fileDuration: TimeInterval, locale: Locale = .autoupdatingCurrent) {
        self.showsHours = fileDuration >= Self.hoursThreshold
        self.decimalSeparator = locale.decimalSeparator ?? "."
    }

    public func string(from time: TimeInterval) -> String {
        let totalHundredths = Int((max(0, time) * 100).rounded())
        let hundredths = totalHundredths % 100
        let totalSeconds = totalHundredths / 100
        let seconds = totalSeconds % 60
        let totalMinutes = totalSeconds / 60

        let fraction = decimalSeparator + twoDigits(hundredths)
        if showsHours {
            return "\(totalMinutes / 60):\(twoDigits(totalMinutes % 60)):\(twoDigits(seconds))\(fraction)"
        }
        return "\(twoDigits(totalMinutes)):\(twoDigits(seconds))\(fraction)"
    }

    public func time(from text: String) -> TimeInterval? {
        let normalized =
            text
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: decimalSeparator, with: ".")
        let parts = normalized.split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }

        guard let seconds = Double(parts[parts.count - 1]), seconds.isFinite, seconds >= 0 else { return nil }
        var total = seconds
        var multiplier: TimeInterval = 60
        for part in parts.dropLast().reversed() {
            guard let whole = Int(part), whole >= 0 else { return nil }
            total += Double(whole) * multiplier
            multiplier *= 60
        }
        return total
    }

    private func twoDigits(_ value: Int) -> String {
        value < 10 ? "0\(value)" : "\(value)"
    }
}
