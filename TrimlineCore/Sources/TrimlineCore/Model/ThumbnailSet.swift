import Foundation

/// Thumbnails for equal slots of `range`; `nil` until a slot's image arrives.
public struct ThumbnailSet: Sendable {
    public static let empty = ThumbnailSet(range: 0...0, count: 0)

    public let range: ClosedRange<TimeInterval>
    public internal(set) var images: [Thumbnail?]
    public internal(set) var isFinished = false

    init(range: ClosedRange<TimeInterval>, count: Int) {
        self.range = range
        images = Array(repeating: nil, count: max(0, count))
    }

    public var isEmpty: Bool { images.isEmpty }

    public func slot(_ index: Int) -> ClosedRange<TimeInterval> {
        guard !images.isEmpty else { return range }
        let length = (range.upperBound - range.lowerBound) / Double(images.count)
        let start = range.lowerBound + Double(index) * length
        return start...(start + length)
    }

    mutating func insert(_ thumbnail: Thumbnail) {
        guard images.indices.contains(thumbnail.index) else { return }
        images[thumbnail.index] = thumbnail
    }
}
