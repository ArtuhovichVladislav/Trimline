import Foundation

public enum ExportMode: String, Sendable, CaseIterable, Codable {
    case fast
    case precise
}

/// Which of a video's tracks the clip keeps.
public enum ExportContent: String, Sendable, CaseIterable, Codable {
    case videoAndSound
    case videoOnly
    /// The sound is copied into an audio file of its codec's own format.
    case soundOnly

    public var keepsVideo: Bool { self != .soundOnly }
    public var keepsSound: Bool { self != .videoOnly }
}

public enum ExportError: Error, Sendable, Equatable {
    case insufficientDiskSpace(required: Int64, available: Int64)
    case destinationExists
    case destinationNotWritable
    case unsupportedFormat
    case cancelled
    case failed(String)
}

public struct ExportRequest: Sendable, Equatable {
    public let source: URL
    public let range: ClosedRange<TimeInterval>
    public let mode: ExportMode
    public let destination: URL
    public let estimatedSize: Int64
    public let content: ExportContent

    public init(
        source: URL,
        range: ClosedRange<TimeInterval>,
        mode: ExportMode,
        destination: URL,
        estimatedSize: Int64,
        content: ExportContent = .videoAndSound
    ) {
        self.source = source
        self.range = range
        self.mode = mode
        self.destination = destination
        self.estimatedSize = estimatedSize
        self.content = content
    }
}
