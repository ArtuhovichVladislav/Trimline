import Foundation
import Testing

@testable import TrimlineCore

@Suite struct MediaEndTests {
    // A DASH-style fragmented MP4 is where AVFoundation doubles the duration; check the probe keeps
    // regular files exact and fragmented ones at their real length.
    @Test func fragmentedMP4KeepsRealDuration() async throws {
        let source = try await TestMedia.audio(.init(duration: 3, fileType: .m4a))
        let folder = try TestMedia.makeTemporaryFolder()
        let fragmented = folder.appendingPathComponent("dash.mp4")
        guard let ffmpeg = ExternalMP3.encoder else { return }
        let process = Process()
        process.executableURL = ffmpeg
        process.arguments = [
            "-v", "error", "-i", source.path, "-c", "copy",
            "-movflags", "frag_keyframe+empty_moov+default_base_moof", "-f", "mp4", fragmented.path,
        ]
        try process.run()
        process.waitUntilExit()

        let engine = try await AVFoundationEngine.open(fragmented)
        #expect(abs(engine.info.duration - 3) < 0.1)
    }

    @Test func regularFileDurationIsUnchanged() async throws {
        let engine = try await AVFoundationEngine.open(try await TestMedia.video())
        #expect(abs(engine.info.duration - 4) < 0.05)
    }
}
