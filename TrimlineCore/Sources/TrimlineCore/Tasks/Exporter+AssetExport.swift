import AVFoundation
import CoreMedia

// Precise mode re-encodes video AVFoundation decodes through AVAssetExportSession, which keeps HDR and
// Dolby Vision the way Apple's apps expect (decision 0008). The session is not Sendable,
// so it is created, polled and cancelled only on the exporter actor.
extension Exporter {
    static let sessionTimescale: CMTimeScale = 90_000

    private static let containers: [String: AVFileType] = [
        "mov": .mov, "qt": .mov,
        "mp4": .mp4, "m4v": .m4v, "m4a": .m4a,
        "3gp": .mobile3GPP, "3gpp": .mobile3GPP, "3g2": .mobile3GPP2,
        "wav": .wav, "wave": .wav,
        "aif": .aiff, "aiff": .aiff, "aifc": .aifc,
        "caf": .caf, "amr": .amr,
    ]

    static func fileType(for source: URL) -> AVFileType? {
        containers[source.pathExtension.lowercased()]
    }

    func exportAsset(
        _ request: ExportRequest,
        to output: URL,
        cancellation: ExportCancellation,
        progress: ExportProgress
    ) async throws(ExportError) {
        guard let fileType = Self.fileType(for: request.source) else { throw .unsupportedFormat }
        let asset = try await Self.asset(for: request)
        guard let preset = await Self.preset(for: asset, fileType: fileType),
            let session = AVAssetExportSession(asset: asset, presetName: preset)
        else { throw .unsupportedFormat }

        session.outputURL = output
        session.outputFileType = fileType
        session.timeRange = CMTimeRange(
            start: CMTime(seconds: request.range.lowerBound, preferredTimescale: Self.sessionTimescale),
            end: CMTime(seconds: request.range.upperBound, preferredTimescale: Self.sessionTimescale)
        )
        session.metadata = (try? await asset.load(.metadata)) ?? []

        try await run(session, cancellation: cancellation, progress: progress)
        if session.status == .failed {
            throw Self.exportError(session.error, request: request)
        }
    }

    // MARK: Private

    private func run(
        _ session: AVAssetExportSession,
        cancellation: ExportCancellation,
        progress: ExportProgress
    ) async throws(ExportError) {
        session.exportAsynchronously {}
        var cancelRequested = false
        while [.unknown, .waiting, .exporting].contains(session.status) {
            if cancellation.isCancelled, !cancelRequested {
                session.cancelExport()
                cancelRequested = true
            }
            progress(Double(session.progress))
            try? await Task.sleep(for: Self.progressInterval)
        }
        if session.status == .cancelled {
            throw .cancelled
        }
    }

    // Video only stays on the session, with HDR and Dolby Vision: the sound tracks are removed from
    // an in-memory copy of the movie, which the session reads like the file itself (decision 0010).
    private static func asset(for request: ExportRequest) async throws(ExportError) -> AVAsset {
        guard !request.content.keepsSound else { return AVURLAsset(url: request.source) }
        let movie = AVMutableMovie(url: request.source, options: nil)
        guard let sound = try? await movie.loadTracks(withMediaType: .audio) else { throw .unsupportedFormat }
        for track in sound {
            movie.removeTrack(track)
        }
        return movie
    }

    /// The session writes only the source's own container, and only video AVFoundation can decode.
    func usesAssetExport(_ request: ExportRequest, container: ExportContainer) async -> Bool {
        guard request.mode == .precise, request.content.keepsVideo, !container.changesContainer,
            let fileType = Self.fileType(for: request.source)
        else { return false }
        let asset = AVURLAsset(url: request.source)
        guard let tracks = try? await asset.loadTracks(withMediaType: .video), !tracks.isEmpty else { return false }
        for track in tracks where (try? await track.load(.isDecodable)) != true {
            return false
        }
        // A smart cut through FFmpeg keeps everything after the first key frame as it was; HDR and
        // Dolby Vision stay with the session, which keeps their metadata (decision 0009).
        var isHDR = false
        for track in tracks {
            let characteristics = (try? await track.load(.mediaCharacteristics)) ?? [.containsHDRVideo]
            isHDR = isHDR || characteristics.contains(.containsHDRVideo)
        }
        if !isHDR, await Self.cutsSmartly(request, container: container) {
            return false
        }
        return await Self.preset(for: asset, fileType: fileType) != nil
    }

    /// Reads the source around both ends of the range, so it runs off the actor.
    private static func cutsSmartly(_ request: ExportRequest, container: ExportContainer) async -> Bool {
        let transcoder = Transcoder(source: request.source, container: container, mode: request.mode)
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: transcoder.cutsSmartly(request.range))
            }
        }
    }

    // H.264 stays H.264; everything else becomes HEVC, the hardware encoder's other codec.
    private static func preset(for asset: AVAsset, fileType: AVFileType) async -> String? {
        guard let track = try? await asset.loadTracks(withMediaType: .video).first else { return nil }
        let formats = (try? await track.load(.formatDescriptions)) ?? []
        let isH264 = formats.contains { CMFormatDescriptionGetMediaSubType($0) == kCMVideoCodecType_H264 }
        let candidates =
            isH264
            ? [AVAssetExportPresetHighestQuality]
            : [AVAssetExportPresetHEVCHighestQuality, AVAssetExportPresetHighestQuality]
        for preset in candidates
        where await AVAssetExportSession.compatibility(ofExportPreset: preset, with: asset, outputFileType: fileType) {
            return preset
        }
        return nil
    }

    private static func exportError(_ error: (any Error)?, request: ExportRequest) -> ExportError {
        guard let error else { return .failed(String(describing: AVAssetExportSession.Status.failed)) }
        let nsError = error as NSError
        if nsError.domain == AVFoundationErrorDomain, nsError.code == AVError.Code.diskFull.rawValue {
            let folder = request.destination.deletingLastPathComponent()
            let available = ExportWorkspace.availableCapacity(of: folder) ?? 0
            return .insufficientDiskSpace(required: request.estimatedSize, available: available)
        }
        if nsError.domain == AVFoundationErrorDomain, nsError.code == AVError.Code.fileFormatNotRecognized.rawValue {
            return .unsupportedFormat
        }
        return .failed(nsError.localizedDescription)
    }
}
