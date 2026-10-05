import CoreGraphics
import Foundation

public enum MediaKind: Sendable, Equatable {
    case video
    case audio
}

public struct MediaInfo: Sendable, Equatable {
    public let url: URL
    public let kind: MediaKind
    public let duration: TimeInterval
    public let fileSize: Int64
    public let displaySize: CGSize?
    public let frameRate: Double?
    public let estimatedBitRate: Double
    public let hasAudio: Bool
    /// All sound tracks together; 0 when the file doesn't tell.
    public let audioBitRate: Double

    public init(
        url: URL,
        kind: MediaKind,
        duration: TimeInterval,
        fileSize: Int64,
        displaySize: CGSize?,
        frameRate: Double?,
        estimatedBitRate: Double,
        hasAudio: Bool = true,
        audioBitRate: Double = 0
    ) {
        self.url = url
        self.kind = kind
        self.duration = duration
        self.fileSize = fileSize
        self.displaySize = displaySize
        self.frameRate = frameRate
        self.estimatedBitRate = estimatedBitRate
        self.hasAudio = hasAudio
        self.audioBitRate = audioBitRate
    }

    public var frameStep: TimeInterval {
        if kind == .video, let frameRate, frameRate > 0 {
            return 1 / frameRate
        }
        return Self.audioStep
    }

    public func estimatedClipSize(length: TimeInterval) -> Int64 {
        if estimatedBitRate > 0 {
            return Int64(estimatedBitRate / 8 * length)
        }
        // Without a bit rate assume the clip takes its proportional share of the file.
        guard duration > 0 else { return fileSize }
        return Int64(Double(fileSize) * min(1, length / duration))
    }

    /// Without the sound's own bit rate both parts are taken as large as the whole.
    public func estimatedClipSize(length: TimeInterval, content: ExportContent) -> Int64 {
        let whole = estimatedClipSize(length: length)
        guard audioBitRate > 0 else { return whole }
        let sound = Int64(audioBitRate / 8 * length)
        switch content {
        case .videoAndSound: return whole
        case .videoOnly: return whole > sound ? whole - sound : whole
        case .soundOnly: return min(whole, sound)
        }
    }

    private static let audioStep: TimeInterval = 0.01
}
