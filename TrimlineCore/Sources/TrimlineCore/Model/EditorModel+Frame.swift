import CoreGraphics
import Foundation

public enum FrameAction: Sendable, Equatable {
    case save
    case copy
}

public struct FrameSaveProposal: Sendable, Equatable {
    public let destination: URL
    public let folderIsWritable: Bool
}

public enum FrameExportState: Sendable, Equatable {
    case idle
    case working(FrameAction)
    /// Waits for the app's save panel: `confirmFrameSave(to:)` or `cancelFrameSave()`.
    case choosingDestination(FrameSaveProposal)
    case saved(URL)
    case copied
    case failed(FrameAction, FrameExportError)
}

public enum FrameExportError: Error, Sendable, Equatable {
    case frameUnavailable
    case destinationExists
    case destinationNotWritable
    case insufficientDiskSpace
    case writeFailed
    case pasteboardUnavailable
}

/// A frame for the pasteboard, with its PNG encoding already made off the main actor.
public struct FramePicture: Sendable {
    public let image: CGImage
    public let pngData: Data
}

typealias FrameRender = Task<CGImage?, Never>

extension EditorModel {
    public var canExportFrame: Bool {
        guard phase == .ready, info?.kind == .video, saveState == .idle else { return false }
        switch frameExport {
        case .working, .choosingDestination: return false
        case .idle, .saved, .copied, .failed: return true
        }
    }

    /// Saves the frame at the playhead next to the original, or asks where when the folder is
    /// read-only or the settings say so.
    public func saveFrame() {
        guard let engine, canExportFrame else { return }
        let time = framePosition()
        let source = engine.info.url
        let duration = engine.info.duration
        let naming = frameNaming
        let alwaysAsks = alwaysAsksForDestination
        let render = startRendering(engine, at: time)
        frameExport = .working(.save)
        frameTask = Task { [weak self] in
            // The name lookup and the permission check touch the disk, which can be a slow network share.
            let (destination, isWritable) = await Task.detached {
                let folder = source.deletingLastPathComponent()
                return (
                    naming.frameURL(for: source, at: time, fileDuration: duration),
                    FileManager.default.isWritableFile(atPath: folder.path)
                )
            }.value
            guard let self, !Task.isCancelled else { return }
            if alwaysAsks || !isWritable {
                self.frameExport = .choosingDestination(
                    FrameSaveProposal(destination: destination, folderIsWritable: isWritable))
            } else {
                await self.writeFrame(render, to: destination)
            }
        }
    }

    public func confirmFrameSave(to destination: URL) {
        guard case .choosingDestination = frameExport, let render = frameRender else { return }
        frameExport = .working(.save)
        frameTask = Task { [weak self] in
            await self?.writeFrame(render, to: destination)
        }
    }

    public func cancelFrameSave() {
        guard case .choosingDestination = frameExport else { return }
        cancelFrameExport()
    }

    /// Renders the frame at the playhead and hands it to `pasteboard`, which reports whether it took it.
    public func copyFrame(to pasteboard: @escaping @MainActor (FramePicture) -> Bool) {
        guard let engine, canExportFrame else { return }
        let render = startRendering(engine, at: framePosition())
        frameExport = .working(.copy)
        frameTask = Task { [weak self] in
            let image = await render.value
            let pngData = await Task.detached { image.flatMap(FrameImageWriter.pngData) }.value
            guard let self, !Task.isCancelled else { return }
            guard let image, let pngData else {
                self.frameExport = .failed(.copy, .frameUnavailable)
                return
            }
            let isCopied = pasteboard(FramePicture(image: image, pngData: pngData))
            self.frameExport = isCopied ? .copied : .failed(.copy, .pasteboardUnavailable)
        }
    }

    public func dismissFrameResult() {
        switch frameExport {
        case .saved, .copied, .failed: frameExport = .idle
        case .idle, .working, .choosingDestination: break
        }
    }

    func cancelFrameExport() {
        frameTask?.cancel()
        frameRender?.cancel()
        frameTask = nil
        frameRender = nil
        frameExport = .idle
    }

    // MARK: Private

    // Playback stops on the frame being taken, so the picture and the playhead agree on it.
    private func framePosition() -> TimeInterval {
        guard isPlaying, let playback else { return currentTime }
        pausePlayback()
        seek(to: playback.currentTime)
        return currentTime
    }

    private func startRendering(_ engine: any MediaEngine, at time: TimeInterval) -> FrameRender {
        frameTask?.cancel()
        frameRender?.cancel()
        let render = Task { await engine.frameImage(at: time) }
        frameRender = render
        return render
    }

    private func writeFrame(_ render: FrameRender, to destination: URL) async {
        let image = await render.value
        guard !Task.isCancelled else { return }
        guard let image else {
            frameExport = .failed(.save, .frameUnavailable)
            return
        }
        let result = await Task.detached {
            Result { () throws(FrameExportError) in try FrameImageWriter.write(image, to: destination) }
        }.value
        guard !Task.isCancelled else { return }
        switch result {
        case .success: frameExport = .saved(destination)
        case .failure(let error): frameExport = .failed(.save, error)
        }
    }
}
