import Foundation

public struct Selection: Sendable, Equatable {
    public static let minimumLength: TimeInterval = 0.1

    public let duration: TimeInterval
    public private(set) var start: TimeInterval
    public private(set) var end: TimeInterval

    public init(duration: TimeInterval) {
        self.duration = max(0, duration)
        self.start = 0
        self.end = self.duration
    }

    public init(duration: TimeInterval, start: TimeInterval, end: TimeInterval) {
        self.init(duration: duration)
        setEnd(end)
        setStart(start)
    }

    public var range: ClosedRange<TimeInterval> { start...end }

    public var length: TimeInterval { end - start }

    public var coversWholeFile: Bool { start == 0 && end == duration }

    private var effectiveMinimumLength: TimeInterval { min(Self.minimumLength, duration) }

    public mutating func setStart(_ time: TimeInterval) {
        start = time.clamped(to: 0...(end - effectiveMinimumLength))
    }

    public mutating func setEnd(_ time: TimeInterval) {
        end = time.clamped(to: (start + effectiveMinimumLength)...duration)
    }

    public mutating func move(by offset: TimeInterval) {
        let shift = offset.clamped(to: -start...(duration - end))
        start += shift
        end += shift
    }

    public mutating func reset() {
        start = 0
        end = duration
    }
}

extension Comparable {
    func clamped(to limits: ClosedRange<Self>) -> Self {
        min(max(self, limits.lowerBound), limits.upperBound)
    }
}
