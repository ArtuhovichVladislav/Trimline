import Foundation

public struct SaveProposal: Sendable, Equatable {
    public let destination: URL
    public let range: ClosedRange<TimeInterval>
    public let folderIsWritable: Bool
    /// The source's container can't be written, so the clip gets another one (`destination` has its extension).
    public let changesContainer: Bool
    /// The clip's location is chosen in a save panel: by the user's setting or because the folder is read-only.
    public let asksForDestination: Bool
    /// The mode the bounds were computed for; fast saving may start earlier, on a key frame.
    public let mode: ExportMode
    /// The sound alone gets its own format, so `destination` follows the content too.
    public let content: ExportContent

    public var length: TimeInterval { range.upperBound - range.lowerBound }
}

public enum SaveState: Sendable, Equatable {
    case idle
    case preparing
    case confirming(SaveProposal)
    case saving(progress: Double)
    case saved(url: URL, length: TimeInterval)
    case failed(ExportError)
}

extension EditorModel {
    /// Precise saving re-encodes the picture of any video either engine opened. Sound is copied unless the
    /// clip's container can't hold it (RealAudio, Monkey's Audio and the like are encoded again either way).
    public var canSavePrecisely: Bool {
        info?.kind == .video
    }

    /// The mode only matters while the picture is kept, and only where copying can't start on the exact frame:
    /// MOV, MP4, M4V and 3GP hide the frames before the cut with an edit list (decision 0006), so there saving
    /// without re-encoding is already exact.
    public var effectiveExportMode: ExportMode {
        guard let info, canSavePrecisely, effectiveExportContent.keepsVideo, !StreamCopyStart.isExact(for: info.url)
        else { return .fast }
        return exportMode
    }

    /// Only a video with sound can drop either.
    public var canChooseExportContent: Bool {
        info?.kind == .video && info?.hasAudio == true
    }

    public var effectiveExportContent: ExportContent { canChooseExportContent ? exportContent : .videoAndSound }

    public func prepareSave() {
        guard engine != nil, saveState == .idle || isSaveFinished else { return }
        pausePlayback()
        saveState = .preparing
        computeSaveProposal()
    }

    // Fast saving may start on an earlier key frame and the sound alone gets its own format,
    // so the real bounds and name depend on the mode and the content.
    func refreshSaveProposal() {
        guard case .confirming = saveState else { return }
        computeSaveProposal()
    }

    private func computeSaveProposal() {
        guard let engine else { return }
        let requested = selection.range
        let source = engine.info.url
        let snapsToKeyframe = startsOnKeyframe(engine.info)
        let naming = naming
        let mode = effectiveExportMode
        let content = effectiveExportContent
        let alwaysAsks = alwaysAsksForDestination
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            let start =
                snapsToKeyframe
                ? await engine.keyframe(atOrBefore: requested.lowerBound)
                : requested.lowerBound
            // Name lookup and the permission check touch the disk, which can be a slow network share.
            // The container depends on the codec in the file's header when the picture is re-encoded.
            let (destination, writable, container) = await Task.detached {
                let folder = source.deletingLastPathComponent()
                let container = ExportContainer.forSource(source, mode: mode, content: content)
                let clip = naming.clipURL(for: source, fileExtension: container.fileExtension)
                return (clip, FileManager.default.isWritableFile(atPath: folder.path), container)
            }.value
            guard let self, !Task.isCancelled else { return }
            self.saveState = .confirming(
                SaveProposal(
                    destination: destination, range: start...requested.upperBound, folderIsWritable: writable,
                    changesContainer: container.changesContainer, asksForDestination: alwaysAsks || !writable,
                    mode: mode, content: content)
            )
        }
    }

    /// `false` while the proposal is being recomputed after a mode or content change; saving must wait for it.
    public var isSaveProposalCurrent: Bool {
        guard case .confirming(let proposal) = saveState else { return false }
        return proposal.mode == effectiveExportMode && proposal.content == effectiveExportContent
    }

    public func confirmSave(to destination: URL) {
        guard case .confirming(let proposal) = saveState, isSaveProposalCurrent, let info else { return }
        let request = ExportRequest(
            source: info.url,
            range: proposal.range,
            mode: proposal.mode,
            destination: destination,
            estimatedSize: info.estimatedClipSize(length: proposal.length, content: proposal.content),
            content: proposal.content
        )
        saveState = .saving(progress: 0)
        saveTask = Task { [weak self, exporter] in
            do {
                for try await progress in exporter.export(request) {
                    // A value sent just before the user cancelled must not bring the progress back.
                    guard !Task.isCancelled else { return }
                    self?.saveState = .saving(progress: progress)
                }
                // A cancelled consumer sees the stream end without an error.
                guard !Task.isCancelled else { return }
                self?.saveState = .saved(url: destination, length: proposal.length)
            } catch ExportError.cancelled {
                self?.saveState = .idle
            } catch let error as ExportError {
                self?.saveState = .failed(error)
            } catch {
                self?.saveState = .failed(.failed(String(describing: error)))
            }
        }
    }

    public func cancelSave() {
        saveTask?.cancel()
        saveState = .idle
    }

    public func dismissSaveResult() {
        saveState = .idle
    }

    private var isSaveFinished: Bool {
        switch saveState {
        case .saved, .failed: true
        default: false
        }
    }
}
