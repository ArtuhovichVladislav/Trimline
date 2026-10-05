import Foundation
import TrimlineCore

extension MediaInfo {
    func summary(using timeFormat: TimeFormat) -> String {
        let length = timeFormat.string(from: duration)
        let size = ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
        switch kind {
        case .audio:
            return String(localized: "Audio, \(length), \(size)")
        case .video:
            guard let displaySize else {
                return String(localized: "Video, \(length), \(size)")
            }
            let resolution = "\(Int(displaySize.width.rounded()))×\(Int(displaySize.height.rounded()))"
            return String(localized: "Video, \(resolution), \(length), \(size)")
        }
    }
}

extension MediaOpenError {
    var reason: String {
        switch self {
        case .damaged:
            String(localized: "The file is damaged or truncated.")
        case .noAudioOrVideo:
            String(localized: "The file contains no audio or video.")
        case .unsupportedCodec(let codec):
            String(localized: "The \(codec) codec is not supported.")
        case .unreadable:
            String(localized: "The file can’t be read. Check that it’s still available and try again.")
        }
    }
}

extension ExportError {
    var reason: String {
        switch self {
        case .insufficientDiskSpace:
            String(localized: "Not enough disk space to save the clip.")
        case .destinationExists:
            String(localized: "A file with this name already exists. Choose another name.")
        case .destinationNotWritable:
            String(localized: "Trimline can’t write to this folder. Choose another location.")
        case .unsupportedFormat:
            String(localized: "Clips can’t be saved in this format.")
        case .cancelled:
            String(localized: "Saving was cancelled.")
        case .failed:
            String(localized: "Something went wrong while saving the clip.")
        }
    }

    var detail: String? {
        switch self {
        case .insufficientDiskSpace(let required, let available):
            let needed = ByteCountFormatter.string(fromByteCount: required, countStyle: .file)
            let free = ByteCountFormatter.string(fromByteCount: available, countStyle: .file)
            return String(localized: "\(needed) needed, \(free) available.")
        default:
            return nil
        }
    }
}
