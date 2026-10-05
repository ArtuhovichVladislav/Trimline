import Foundation
import os

// Everything but precise saving of video AVFoundation reads goes through libavformat: a stream copy,
// or a transcode when the picture or a sound track has to be encoded again.
extension Exporter {
    private static let logger = Logger(subsystem: "Trimline", category: "Export")

    func writeWithFFmpeg(
        _ request: ExportRequest,
        container: ExportContainer,
        to output: URL,
        cancellation: ExportCancellation,
        progress: @escaping ExportProgress
    ) async throws(ExportError) {
        let transcoder = Transcoder(source: request.source, container: container, mode: request.mode)
        let observer = copyObserver
        let result = await withCheckedContinuation { continuation in
            // The work blocks on file I/O and the codecs, so it runs on its own thread instead of the actor's.
            DispatchQueue.global(qos: .userInitiated).async {
                let outcome = Result { () throws(RemuxError) in
                    try transcoder.export(
                        request.range, to: output, isCancelled: { cancellation.isCancelled },
                        progress: { value in
                            observer?(value)
                            progress(value)
                        })
                }
                continuation.resume(returning: outcome)
            }
        }
        switch result {
        case .success(let skipped):
            for stream in skipped {
                Self.logger.notice(
                    "Skipped stream \(stream.index) (\(stream.codec)): \(String(describing: stream.reason))")
            }
        case .failure(let error):
            throw Self.exportError(error, request: request)
        }
    }

    /// Reads the source's header, so it runs off the actor.
    static func container(for request: ExportRequest) async -> ExportContainer {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(
                    returning: ExportContainer.forSource(request.source, mode: request.mode, content: request.content))
            }
        }
    }

    private static func exportError(_ error: RemuxError, request: ExportRequest) -> ExportError {
        switch error {
        case .unreadable, .noStreams:
            return .unsupportedFormat
        case .cancelled:
            return .cancelled
        case .diskFull:
            let folder = request.destination.deletingLastPathComponent()
            let available = ExportWorkspace.availableCapacity(of: folder) ?? 0
            return .insufficientDiskSpace(required: request.estimatedSize, available: available)
        case .ffmpeg(let error):
            return .failed(error.description)
        }
    }
}
