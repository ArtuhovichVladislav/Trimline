import CoreMedia
import Foundation
import Testing
import libavutil

@testable import TrimlineCore

// Timestamps come from files, and a malformed one must fail an export, not trap.
@Suite struct FFmpegTimeTests {
    private static let milliseconds = AVRational(num: 1, den: 1000)

    @Test func timestampSaturatesInsteadOfTrapping() {
        #expect(FFmpegTime.timestamp(1.5, in: Self.milliseconds) == 1500)
        #expect(FFmpegTime.timestamp(.infinity, in: Self.milliseconds) == .max)
        #expect(FFmpegTime.timestamp(-.infinity, in: Self.milliseconds) == -Int64.max)
        #expect(FFmpegTime.timestamp(1e300, in: Self.milliseconds) == .max)
        #expect(FFmpegTime.timestamp(.nan, in: Self.milliseconds) == 0)
        // Saturation never produces the "no value" marker.
        #expect(FFmpegTime.timestamp(-1e300, in: Self.milliseconds) != FFmpegTime.noValue)
    }

    @Test func roundedRejectsWhatInt64CantHold() {
        #expect(FFmpegTime.rounded(2.5) == 3)
        #expect(FFmpegTime.rounded(.nan) == nil)
        #expect(FFmpegTime.rounded(.infinity) == nil)
        #expect(FFmpegTime.rounded(1e19) == nil)
        #expect(FFmpegTime.rounded(-1e19) == nil)
    }

    @Test func cmTimeOfAnOverflowingValueIsInvalid() {
        #expect(FFmpegTime.cmTime(3, in: AVRational(num: 1001, den: 30000)) == CMTime(value: 3003, timescale: 30000))
        #expect(!FFmpegTime.cmTime(.max / 2, in: AVRational(num: 1001, den: 30000)).isValid)
        #expect(!FFmpegTime.cmTime(FFmpegTime.noValue, in: Self.milliseconds).isValid)
    }

    @Test func arithmeticReportsOverflowAsInvalidData() throws {
        #expect(try FFmpegTime.sum(2, 3) == 5)
        #expect(try FFmpegTime.difference(2, 3) == -1)
        #expect(throws: FFmpegError.self) { try FFmpegTime.sum(.max, 1) }
        #expect(throws: FFmpegError.self) { try FFmpegTime.difference(.min + 1, 2) }
        do {
            _ = try FFmpegTime.sum(.max - 1, .max - 1)
            Issue.record("An overflow must throw")
        } catch {
            #expect(error.code == FFmpegError.invalidData.code)
        }
    }

    @Test func retimingAHugeTimestampThrows() throws {
        var track = RemuxTrack(
            inputIndex: 0, outputIndex: 0, role: .audio, inputTimeBase: Self.milliseconds,
            outputTimeBase: Self.milliseconds)
        let window = RemuxWindow(
            origin: RemuxTime(seconds: 10), firstPrimary: RemuxTime(seconds: 10), end: RemuxTime(seconds: 20),
            hidesPreroll: false, primaryIndex: 0)
        let packet = try Packet()
        packet.pointer.pointee.pts = -Int64.max
        packet.pointer.pointee.dts = -Int64.max
        #expect(throws: FFmpegError.self) {
            try track.retime(packet, window: window, allowsEqualDts: false)
        }

        let next = try Packet()
        next.pointer.pointee.pts = 12_000
        next.pointer.pointee.dts = 12_000
        next.pointer.pointee.duration = .max
        try track.retime(next, window: window, allowsEqualDts: false)
        #expect(next.pts == 2000)
        // dts + duration overflows: the next packet without a time is left without one instead of trapping.
        #expect(track.nextInputDts == FFmpegTime.noValue)
    }
}
