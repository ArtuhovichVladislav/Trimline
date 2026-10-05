import AVFoundation
import Testing

@Suite struct TestMediaTests {
    @Test func generatesPlayableVideoAndAudio() async throws {
        let video = try await TestMedia.video()
        let audio = try await TestMedia.audio(.init(fileType: .m4a))
        let videoDuration = try await AVURLAsset(url: video).load(.duration).seconds
        let audioDuration = try await AVURLAsset(url: audio).load(.duration).seconds
        #expect(abs(videoDuration - 4) < 0.1)
        #expect(abs(audioDuration - 3) < 0.1)
    }
}
