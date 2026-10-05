import CoreGraphics
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

// PNG is lossless and opens everywhere; the image's color space is embedded as a profile.
enum FrameImageWriter {
    // Hidden and next to the destination, so the final rename stays on one volume.
    private static let temporaryPrefix = ".trimline-frame-"

    static func pngData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    /// Writes a temporary file and renames it into place: a partial image never carries the final
    /// name, and an existing file is never replaced.
    static func write(_ image: CGImage, to destination: URL) throws(FrameExportError) {
        guard let data = pngData(image) else { throw .writeFailed }
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(temporaryPrefix + UUID().uuidString + "." + FrameNaming.fileExtension)
        // Before the write, so a partly written file goes too.
        defer { try? FileManager.default.removeItem(at: temporary) }
        do {
            try data.write(to: temporary, options: .withoutOverwriting)
        } catch {
            throw exportError(for: error)
        }
        try publish(temporary, as: destination)
    }

    // MARK: Private

    private static func publish(_ temporary: URL, as destination: URL) throws(FrameExportError) {
        // RENAME_EXCL makes the rename fail instead of replacing a file created in the meantime.
        guard renamex_np(temporary.path, destination.path, UInt32(RENAME_EXCL)) != 0 else { return }
        switch errno {
        case EEXIST:
            throw .destinationExists
        case ENOTSUP, EINVAL:
            do {
                try FileManager.default.moveItem(at: temporary, to: destination)
            } catch {
                throw exportError(for: error)
            }
        case EACCES, EPERM, EROFS:
            throw .destinationNotWritable
        case ENOSPC:
            throw .insufficientDiskSpace
        default:
            throw .writeFailed
        }
    }

    private static func exportError(for error: any Error) -> FrameExportError {
        guard let error = error as? CocoaError else { return .writeFailed }
        switch error.code {
        case .fileWriteFileExists:
            return .destinationExists
        case .fileWriteOutOfSpace:
            return .insufficientDiskSpace
        case .fileWriteNoPermission, .fileWriteVolumeReadOnly, .fileNoSuchFile, .fileWriteInvalidFileName:
            return .destinationNotWritable
        default:
            return .writeFailed
        }
    }
}
