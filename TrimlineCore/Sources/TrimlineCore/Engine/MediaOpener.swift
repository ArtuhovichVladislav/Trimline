import Foundation

public enum MediaOpenError: Error, Sendable, Equatable {
    case damaged
    case noAudioOrVideo
    case unsupportedCodec(String)
    case unreadable
}

public enum MediaOpener {
    // Probing, not the file extension, picks the engine: extensions lie (decision 0001).
    public static func open(_ url: URL) async throws(MediaOpenError) -> any MediaEngine {
        try await open(
            url,
            native: { url throws(MediaOpenError) in try await AVFoundationEngine.open(url) },
            fallback: { url throws(MediaOpenError) in try await FFmpegEngine.open(url) }
        )
    }

    typealias Engine = @Sendable (URL) async throws(MediaOpenError) -> any MediaEngine

    static func open(_ url: URL, native: Engine, fallback: Engine) async throws(MediaOpenError) -> any MediaEngine {
        let nativeError: MediaOpenError
        do {
            return try await native(url)
        } catch {
            nativeError = error
        }
        // The file itself can't be read; FFmpeg would only say the same.
        guard nativeError != .unreadable else { throw nativeError }
        do {
            return try await fallback(url)
        } catch {
            throw moreInformative(nativeError, error)
        }
    }

    // AVFoundation says "damaged" about anything it doesn't know, so FFmpeg's verdict usually tells more.
    static func moreInformative(_ native: MediaOpenError, _ fallback: MediaOpenError) -> MediaOpenError {
        switch (native, fallback) {
        case (_, .unsupportedCodec), (_, .noAudioOrVideo), (_, .unreadable): fallback
        case (.unsupportedCodec, _), (.noAudioOrVideo, _): native
        default: fallback
        }
    }
}
