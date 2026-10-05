import AVFoundation
import Foundation
import Testing

@testable import TrimlineCore

@Suite struct EngineOpeningTests {
    @Test func opensMovieWithVideoInfo() async throws {
        let url = try await TestMedia.video()
        let info = try await MediaOpener.open(url).info

        #expect(info.url == url)
        #expect(info.kind == .video)
        #expect(abs(info.duration - 4) < 0.1)
        #expect(info.displaySize == CGSize(width: 320, height: 180))
        #expect(abs((info.frameRate ?? 0) - 30) < 0.5)
        #expect(info.fileSize == fileSize(of: url))
        #expect(info.estimatedBitRate > 0)
    }

    @Test(arguments: [AVFileType.m4a, .wav])
    func opensAudioFile(_ fileType: AVFileType) async throws {
        let url = try await TestMedia.audio(.init(fileType: fileType))
        let info = try await MediaOpener.open(url).info

        #expect(info.kind == .audio)
        #expect(abs(info.duration - 3) < 0.1)
        #expect(info.displaySize == nil)
        #expect(info.frameRate == nil)
        #expect(info.fileSize == fileSize(of: url))
        #expect(info.estimatedBitRate > 0)
    }

    @Test func reportsGarbageAsDamaged() async throws {
        let url = try TestMedia.garbage()
        await #expect(throws: MediaOpenError.damaged) {
            try await MediaOpener.open(url)
        }
    }

    @Test func reportsMissingFileAsUnreadable() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID().uuidString).mov")
        await #expect(throws: MediaOpenError.unreadable) {
            try await MediaOpener.open(url)
        }
    }

    @Test func reportsFolderAsUnreadable() async throws {
        let folder = try TestMedia.makeTemporaryFolder()
        await #expect(throws: MediaOpenError.unreadable) {
            try await MediaOpener.open(folder)
        }
    }

    @Test func namesCodecsFromFourCharacterCodes() {
        #expect(CodecName.fourCharacterCode(kCMVideoCodecType_H264) == "avc1")
        #expect(CodecName.fourCharacterCode(kAudioFormatMPEG4AAC) == "aac")
        #expect(CodecName.fourCharacterCode(0x0102_0304) == "0x01020304")
    }

    private func fileSize(of url: URL) -> Int64? {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0.map(Int64.init) }
    }
}
