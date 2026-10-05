import AVFoundation
import Foundation
import Testing

@testable import TrimlineCore

@Suite struct MediaOpenerTests {
    @Test(arguments: [AVFileType.mov, .mp4])
    func opensAppleMoviesWithAVFoundation(_ fileType: AVFileType) async throws {
        let engine = try await MediaOpener.open(try await TestMedia.video(.init(fileType: fileType)))
        #expect(engine is AVFoundationEngine)
    }

    @Test(
        .enabled(if: ExternalFFmpeg.isAvailable),
        arguments: [FFmpegFixtures.h264MKV, FFmpegFixtures.vp8WebM, FFmpegFixtures.mpeg4AVI])
    func opensOtherMoviesWithFFmpeg(_ movie: FFmpegFixtures.Movie) async throws {
        let engine = try await MediaOpener.open(try movie.make())
        #expect(engine is FFmpegEngine)
        #expect(engine.info.kind == .video)
    }

    @Test(.enabled(if: ExternalFFmpeg.isAvailable))
    func opensWindowsMediaAudioWithFFmpeg() async throws {
        let engine = try await MediaOpener.open(try FFmpegFixtures.wma.make())
        #expect(engine is FFmpegEngine)
        #expect(engine.info.kind == .audio)
    }

    // Newer macOS versions read Ogg themselves; either engine is fine as long as the file opens.
    @Test(.enabled(if: ExternalFFmpeg.isAvailable), arguments: [FFmpegFixtures.oggVorbis, FFmpegFixtures.opus])
    func opensOggAudio(_ audio: FFmpegFixtures.AudioFile) async throws {
        let info = try await MediaOpener.open(try audio.make()).info
        #expect(info.kind == .audio)
        #expect(abs(info.duration - Double(FFmpegFixtures.toneSeconds)) < 0.1)
    }

    @Test(.enabled(if: ExternalFFmpeg.isAvailable))
    func reportsCodecNamedByFFmpeg() async throws {
        await #expect(throws: MediaOpenError.unsupportedCodec("FFV1")) {
            try await MediaOpener.open(try FFmpegFixtures.unsupportedVideo())
        }
    }

    @Test func skipsFallbackForUnreadableFile() async throws {
        let attempts = Attempts()
        await #expect(throws: MediaOpenError.unreadable) {
            try await MediaOpener.open(
                URL(fileURLWithPath: "/missing"),
                native: { _ throws(MediaOpenError) in throw .unreadable },
                fallback: { _ throws(MediaOpenError) in
                    await attempts.record()
                    throw .damaged
                }
            )
        }
        #expect(await attempts.count == 0)
    }

    @Test(arguments: [
        (MediaOpenError.damaged, MediaOpenError.unsupportedCodec("Bink"), MediaOpenError.unsupportedCodec("Bink")),
        (.damaged, .noAudioOrVideo, .noAudioOrVideo),
        (.unsupportedCodec("avc1"), .damaged, .unsupportedCodec("avc1")),
        (.noAudioOrVideo, .damaged, .noAudioOrVideo),
        (.damaged, .damaged, .damaged),
        (.unsupportedCodec("0x01020304"), .unsupportedCodec("Bink"), .unsupportedCodec("Bink")),
    ])
    func prefersMoreInformativeError(native: MediaOpenError, fallback: MediaOpenError, expected: MediaOpenError) {
        #expect(MediaOpener.moreInformative(native, fallback) == expected)
    }
}

private actor Attempts {
    private(set) var count = 0

    func record() {
        count += 1
    }
}
