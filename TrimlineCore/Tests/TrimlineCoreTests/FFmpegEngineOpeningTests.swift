import CoreGraphics
import Foundation
import Testing

@testable import TrimlineCore

@Suite(.enabled(if: ExternalFFmpeg.isAvailable)) struct FFmpegEngineOpeningTests {
    @Test(arguments: FFmpegFixtures.movies)
    func opensMovie(_ movie: FFmpegFixtures.Movie) async throws {
        try await expectMovieInfo(of: movie.make())
    }

    @Test(.enabled(if: FFmpegFixtures.hasEncoder("libsvtav1")))
    func opensAV1WebM() async throws {
        try await expectMovieInfo(of: FFmpegFixtures.av1WebM.make())
    }

    @Test(arguments: FFmpegFixtures.audioFiles)
    func opensAudio(_ audio: FFmpegFixtures.AudioFile) async throws {
        let info = try await FFmpegEngine.open(try audio.make()).info
        #expect(info.kind == .audio)
        #expect(abs(info.duration - Double(FFmpegFixtures.toneSeconds)) < 0.1)
        #expect(info.displaySize == nil)
        #expect(info.frameRate == nil)
        #expect(info.estimatedBitRate > 0)
    }

    @Test func swapsDisplaySizeOfRotatedVideo() async throws {
        let info = try await FFmpegEngine.open(try FFmpegFixtures.rotatedMKV()).info
        #expect(info.displaySize == CGSize(width: 180, height: 320))
    }

    @Test func namesUnsupportedVideoCodec() async throws {
        await #expect(throws: MediaOpenError.unsupportedCodec("FFV1")) {
            try await FFmpegEngine.open(try FFmpegFixtures.unsupportedVideo())
        }
    }

    @Test func namesUnsupportedAudioCodec() async throws {
        await #expect(throws: MediaOpenError.unsupportedCodec("Nellymoser")) {
            try await FFmpegEngine.open(try FFmpegFixtures.unsupportedAudio())
        }
    }

    @Test func reportsSubtitlesOnlyFileAsEmpty() async throws {
        await #expect(throws: MediaOpenError.noAudioOrVideo) {
            try await FFmpegEngine.open(try FFmpegFixtures.subtitlesOnly())
        }
    }

    @Test func reportsGarbageAsDamaged() async throws {
        await #expect(throws: MediaOpenError.damaged) {
            try await FFmpegEngine.open(try TestMedia.garbage(extension: "mkv"))
        }
    }

    @Test func reportsMissingFileAsUnreadable() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID().uuidString).mkv")
        await #expect(throws: MediaOpenError.unreadable) {
            try await FFmpegEngine.open(url)
        }
    }

    @Test func namesCodecsForPeople() {
        #expect(FFmpegCodecName.displayName(forCodecNamed: "binkvideo") == "Bink")
        #expect(FFmpegCodecName.displayName(forCodecNamed: "adpcm_g726") == "ADPCM")
        #expect(FFmpegCodecName.displayName(forCodecNamed: "zmbv") == "zmbv")
    }

    private func expectMovieInfo(of url: URL) async throws {
        let info = try await FFmpegEngine.open(url).info
        #expect(info.url == url)
        #expect(info.kind == .video)
        #expect(abs(info.duration - 4) < 0.15)
        #expect(info.displaySize == CGSize(width: 320, height: 180))
        #expect(abs((info.frameRate ?? 0) - 25) < 0.5)
        #expect(info.fileSize == (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init))
        #expect(info.estimatedBitRate > 0)
    }
}
