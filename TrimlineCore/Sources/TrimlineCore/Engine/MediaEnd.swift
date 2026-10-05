import AVFoundation

// AVFoundation reports twice the real duration for some fragmented MP4 files (YouTube DASH audio):
// the track's edit claims more time than there are samples, and everything past the last sample
// plays as silence. The index knows where the samples really end, so trust it when the two disagree
// by much more than edit-list rounding.
enum MediaEnd {
    private static let minimumMismatch: TimeInterval = 1
    private static let minimumMismatchFraction = 0.05
    // Enough to pass B-frame reordering at the end of a video track.
    private static let samplesToInspect = 16

    static func correctedDuration(_ headerDuration: CMTime, tracks: [AVAssetTrack]) async -> CMTime {
        guard headerDuration.isNumeric else { return headerDuration }
        var ends: [CMTime] = []
        for track in tracks {
            guard (try? await track.load(.canProvideSampleCursors)) == true, let end = lastSampleEnd(of: track) else {
                return headerDuration
            }
            ends.append(end)
        }
        guard let mediaEnd = ends.max() else { return headerDuration }
        let mismatch = headerDuration.seconds - mediaEnd.seconds
        guard mismatch > max(minimumMismatch, headerDuration.seconds * minimumMismatchFraction) else {
            return headerDuration
        }
        return mediaEnd
    }

    private static func lastSampleEnd(of track: AVAssetTrack) -> CMTime? {
        guard let cursor = track.makeSampleCursorAtLastSampleInDecodeOrder() else { return nil }
        var end = CMTime.zero
        for _ in 0..<samplesToInspect {
            let sampleEnd = cursor.presentationTimeStamp + cursor.currentSampleDuration
            if sampleEnd.isNumeric, sampleEnd > end { end = sampleEnd }
            guard cursor.stepInDecodeOrder(byCount: -1) == -1 else { break }
        }
        return end > .zero ? end : nil
    }
}
