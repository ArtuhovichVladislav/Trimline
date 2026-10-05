import AVFoundation
import Foundation

struct AssetProbe: Sendable {
    struct VideoTrackReference: Sendable {
        let id: CMPersistentTrackID
        let timescale: CMTimeScale
    }

    let asset: AVURLAsset
    let info: MediaInfo
    let videoTrack: VideoTrackReference?
    let fileIdentity: WaveformCache.FileIdentity?

    static func run(_ url: URL) async throws(MediaOpenError) -> AssetProbe {
        let file = try MediaFile(url)
        // Precise timing makes AVFoundation scan the whole file; the header is enough for us.
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: false])
        let (summaries, duration) = try await loadMediaTracks(of: asset)
        let primary = try selectPrimaryTrack(from: summaries)

        let seconds = duration.isNumeric ? max(0, duration.seconds) : 0
        let info = MediaInfo(
            url: url,
            kind: primary.isVisual ? .video : .audio,
            duration: seconds,
            fileSize: file.size,
            displaySize: primary.displaySize,
            frameRate: primary.frameRate,
            estimatedBitRate: estimatedBitRate(of: summaries, file: file, duration: seconds),
            hasAudio: summaries.contains(where: \.carriesSound),
            audioBitRate: audioBitRate(of: summaries)
        )
        return AssetProbe(
            asset: asset,
            info: info,
            videoTrack: primary.isVisual ? VideoTrackReference(id: primary.id, timescale: primary.timescale) : nil,
            fileIdentity: file.waveformIdentity
        )
    }

    private static func loadMediaTracks(
        of asset: AVURLAsset
    ) async throws(MediaOpenError) -> (tracks: [TrackSummary], duration: CMTime) {
        do {
            let (tracks, duration) = try await asset.load(.tracks, .duration)
            guard !tracks.isEmpty else { throw MediaOpenError.damaged }
            var summaries: [TrackSummary] = []
            let mediaTracks = tracks.filter { TrackSummary.isMedia($0.mediaType) }
            for track in mediaTracks {
                summaries.append(try await TrackSummary.load(track))
            }
            return (summaries, await MediaEnd.correctedDuration(duration, tracks: mediaTracks))
        } catch let error as MediaOpenError {
            throw error
        } catch {
            throw openError(for: error)
        }
    }

    // A video file with an unplayable picture is reported as unsupported even if its sound would play.
    private static func selectPrimaryTrack(from summaries: [TrackSummary]) throws(MediaOpenError) -> TrackSummary {
        guard !summaries.isEmpty else { throw .noAudioOrVideo }
        let visual = summaries.filter(\.isVisual)
        let candidates = visual.isEmpty ? summaries : visual
        guard let playable = candidates.first(where: \.isPlayable) else {
            throw .unsupportedCodec(candidates.first?.codecName ?? CodecName.unknown)
        }
        return playable
    }

    private static func estimatedBitRate(of summaries: [TrackSummary], file: MediaFile, duration: TimeInterval)
        -> Double
    {
        let reported = summaries.reduce(0) { $0 + Double($1.dataRate) }
        return reported > 0 ? reported : file.averageBitRate(duration: duration)
    }

    // Sound inside a muxed track has no rate of its own.
    private static func audioBitRate(of summaries: [TrackSummary]) -> Double {
        let sound = summaries.filter(\.carriesSound)
        guard sound.allSatisfy({ !$0.isVisual && $0.dataRate > 0 }) else { return 0 }
        return sound.reduce(0) { $0 + Double($1.dataRate) }
    }

    private static func openError(for error: any Error) -> MediaOpenError {
        isAccessError(error as NSError) ? .unreadable : .damaged
    }

    private static func isAccessError(_ error: NSError) -> Bool {
        switch (error.domain, error.code) {
        case (NSCocoaErrorDomain, NSFileReadNoPermissionError),
            (NSCocoaErrorDomain, NSFileReadNoSuchFileError),
            (NSURLErrorDomain, NSURLErrorNoPermissionsToReadFile),
            (NSURLErrorDomain, NSURLErrorFileDoesNotExist),
            (NSPOSIXErrorDomain, Int(EACCES)),
            (NSPOSIXErrorDomain, Int(EPERM)),
            (NSPOSIXErrorDomain, Int(ENOENT)):
            return true
        default:
            guard let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError else { return false }
            return isAccessError(underlying)
        }
    }
}

private struct TrackSummary {
    let id: CMPersistentTrackID
    let isVisual: Bool
    let carriesSound: Bool
    let isPlayable: Bool
    let codecName: String
    let dataRate: Float
    let displaySize: CGSize?
    let frameRate: Double?
    let timescale: CMTimeScale

    // Muxed tracks come from MPEG program streams and DV, which carry picture and sound together.
    static func isMedia(_ type: AVMediaType) -> Bool {
        type == .video || type == .audio || type == .muxed
    }

    static func load(_ track: AVAssetTrack) async throws -> TrackSummary {
        let (isPlayable, formats, dataRate, timescale) = try await track.load(
            .isPlayable, .formatDescriptions, .estimatedDataRate, .naturalTimeScale
        )
        let isVisual = track.mediaType != .audio
        var displaySize: CGSize?
        var frameRate: Double?
        if isVisual {
            let (naturalSize, transform, nominalRate) = try await track.load(
                .naturalSize, .preferredTransform, .nominalFrameRate
            )
            let rotated = naturalSize.applying(transform)
            displaySize = rotated == .zero ? nil : CGSize(width: abs(rotated.width), height: abs(rotated.height))
            frameRate = nominalRate > 0 ? Double(nominalRate) : nil
        }
        return TrackSummary(
            id: track.trackID,
            isVisual: isVisual,
            carriesSound: track.mediaType == .audio || track.mediaType == .muxed,
            isPlayable: isPlayable,
            codecName: CodecName.displayName(for: formats.first),
            dataRate: dataRate,
            displaySize: displaySize,
            frameRate: frameRate,
            timescale: timescale
        )
    }
}

enum CodecName {
    static let unknown = "?"

    private static let printableASCII: ClosedRange<UInt8> = 0x20...0x7E

    private static let knownNames: [String: String] = [
        "avc1": "H.264", "avc3": "H.264", "hvc1": "HEVC", "hev1": "HEVC", "dvh1": "Dolby Vision",
        "vp09": "VP9", "av01": "AV1", "mp4v": "MPEG-4", "mp2v": "MPEG-2",
        "apch": "ProRes", "apcn": "ProRes", "apcs": "ProRes", "apco": "ProRes", "ap4h": "ProRes", "ap4x": "ProRes",
        "aac": "AAC", ".mp3": "MP3", "ac-3": "AC-3", "ec-3": "E-AC-3", "opus": "Opus", "fLaC": "FLAC",
        "alac": "ALAC", "lpcm": "PCM",
    ]

    static func displayName(for format: CMFormatDescription?) -> String {
        guard let format else { return unknown }
        let code = fourCharacterCode(CMFormatDescriptionGetMediaSubType(format))
        return knownNames[code] ?? code
    }

    static func fourCharacterCode(_ value: FourCharCode) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: value >> $0) }
        let isPrintable = bytes.allSatisfy { printableASCII.contains($0) }
        guard isPrintable else { return String(format: "0x%08X", value) }
        return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespaces)
    }
}
