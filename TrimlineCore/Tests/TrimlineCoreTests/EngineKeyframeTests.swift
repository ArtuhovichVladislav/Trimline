import Foundation
import Testing

@testable import TrimlineCore

@Suite struct EngineKeyframeTests {
    @Test(arguments: [(2.5, 2.0), (2.0, 2.0), (1.99, 1.0), (0.4, 0.0), (3.9, 3.0)])
    func findsPreviousKeyframe(requested: TimeInterval, expected: TimeInterval) async throws {
        let url = try await TestMedia.video(.init(frameRate: 30, keyframeInterval: 30))
        let engine = try await MediaOpener.open(url)
        let keyframe = await engine.keyframe(atOrBefore: requested)
        #expect(abs(keyframe - expected) < 0.001)
    }

    @Test func returnsAudioTimeUnchanged() async throws {
        let url = try await TestMedia.audio()
        let engine = try await MediaOpener.open(url)
        #expect(await engine.keyframe(atOrBefore: 1.234) == 1.234)
    }
}
