import Foundation
import Testing

@testable import TrimlineCore

@Suite(.serialized, .enabled(if: ExternalFFmpeg.isAvailable)) struct SmartCutTests {
    typealias Source = SmartCutFixtures.Source

    // Starts on frame 13, mid-GOP; the junction is the key frame at 2.4 s, and the copy crosses the next
    // key frame at 4.8 s.
    private static let range: ClosedRange<TimeInterval> = 0.52...5.2
    private static let frame = 1 / SmartCutFixtures.frameRate
    private static let colorTolerance = 4.0
    private static let junctionFrame = SmartCutFixtures.keyframeInterval
    private static let maximumOutro = 3

    @Test(arguments: [
        Source.matroskaH264, .mp4H264, .movH264, .tsH264, .matroskaHEVC, .tsHEVC, .matroskaHEVC10,
    ])
    func copiesEverythingAfterTheJunction(_ fixture: Source) async throws {
        let source = try SmartCutFixtures.make(fixture)
        let clip = try transcode(source)
        let report = try FFprobe.report(clip)
        #expect(report.streams.filter { $0.codecType == "video" }.map(\.codecName) == [fixture.codec])
        #expect(report.streams.count { $0.codecType == "audio" } == 1)
        try await expectFrames(of: clip, from: source, isQuickTime: fixture.isQuickTime)

        let (encoded, copied) = try packetOrigins(of: clip, in: source)
        let shown = try shownFrames(of: source, in: Self.range)
        let head = Self.junctionFrame - shown.lowerBound
        // The outro before the end is a frame or two of the last mini-GOP; copied key frames get the
        // source's parameter sets back in front, every other copied packet is the source's own.
        #expect(encoded >= head && encoded <= head + Self.maximumOutro)
        #expect(copied >= shown.count - head - Self.maximumOutro - 2)
    }

    // x265's open GOPs start on clean random access pictures whose leading B-frames refer to the GOP
    // before; the head encodes those frames and the copy starts with a broken link picture instead.
    @Test func handlesOpenGOPs() async throws {
        let source = try SmartCutFixtures.make(.matroskaHEVCOpenGOP)
        let clip = try transcode(source)
        try await expectFrames(of: clip, from: source, isQuickTime: false)
        let (_, copied) = try packetOrigins(of: clip, in: source)
        #expect(copied > (try shownFrames(of: source, in: Self.range)).count / 2)
    }

    // AVFoundation's HEVC decoder refuses the head's own parameter sets in the copy's sample description.
    // (This path is taken only for files AVFoundation can't read, so the clip is checked with FFmpeg.)
    @Test(arguments: [Source.mp4HEVC, .mp4HEVCOpenGOP])
    func hevcInQuickTimeIsEncodedWhole(_ fixture: Source) async throws {
        let source = try SmartCutFixtures.make(fixture)
        let clip = try transcode(source)
        try await expectFrames(of: clip, from: source, isQuickTime: false)
        #expect(try packetOrigins(of: clip, in: source).copied == 0)
    }

    // To the end of the file nothing refers past the end either: the clip is the source's packets alone.
    @Test(arguments: [Source.matroskaH264, .mp4H264, .matroskaHEVC])
    func startOnAKeyFrameIsAPlainCopy(_ fixture: Source) async throws {
        let range: ClosedRange<TimeInterval> = 2.4...Double(SmartCutFixtures.duration)
        let source = try SmartCutFixtures.make(fixture)
        let clip = try transcode(source, range: range)
        try await expectFrames(of: clip, from: source, range: range, isQuickTime: fixture.isQuickTime)
        let (encoded, copied) = try packetOrigins(of: clip, in: source)
        #expect(encoded == 0)
        #expect(copied == (try shownFrames(of: source, in: range)).count)
    }

    // The end lands in the middle of a mini-GOP whose last frame is shown after it.
    @Test(arguments: [Source.matroskaH264, .mp4H264, .tsHEVC])
    func endBetweenReferencesIsExact(_ fixture: Source) async throws {
        let range: ClosedRange<TimeInterval> = 2.4...4.1
        let source = try SmartCutFixtures.make(fixture)
        let clip = try transcode(source, range: range)
        try await expectFrames(of: clip, from: source, range: range, isQuickTime: fixture.isQuickTime)
        #expect(try packetOrigins(of: clip, in: source).copied > 0)
    }

    @Test(arguments: [Source.matroskaH264, .mp4H264])
    func clipEndingBeforeTheNextKeyFrameIsEncodedWhole(_ fixture: Source) async throws {
        let range: ClosedRange<TimeInterval> = 0.52...2.0
        let source = try SmartCutFixtures.make(fixture)
        let clip = try transcode(source, range: range)
        try await expectFrames(of: clip, from: source, range: range, isQuickTime: fixture.isQuickTime)
        #expect(try packetOrigins(of: clip, in: source).copied == 0)
    }

    // The hardware encoder writes no 10-bit H.264, so such a picture is encoded whole, as before.
    @Test func unsupportedProfileIsEncodedWhole() async throws {
        let source = try SmartCutFixtures.make(.matroskaH264TenBit)
        let clip = try transcode(source)
        #expect(try packetOrigins(of: clip, in: source).copied == 0)
        let shown = try TranscodeFixtures.averageRed(of: clip, at: 0)
        #expect(abs(shown - (try TranscodeFixtures.averageRed(of: source, at: Self.range.lowerBound))) < 4)
    }

    // MARK: Through the exporter

    @Test(arguments: [Source.mp4H264, .movH264, .matroskaHEVC])
    func exporterCutsSmartly(_ fixture: Source) async throws {
        let source = try SmartCutFixtures.make(fixture)
        let clip = try await export(source, content: .videoAndSound)
        #expect(clip.pathExtension == fixture.fileExtension)
        try await expectFrames(of: clip, from: source, isQuickTime: fixture.isQuickTime)
        #expect(try isSmartCut(clip, from: source))
    }

    @Test(arguments: [Source.mp4H264, .matroskaH264])
    func videoOnlyCutsSmartly(_ fixture: Source) async throws {
        let source = try SmartCutFixtures.make(fixture)
        let clip = try await export(source, content: .videoOnly)
        #expect(try FFprobe.report(clip).streams.map(\.codecType) == ["video"])
        try await expectFrames(of: clip, from: source, isQuickTime: fixture.isQuickTime)
        #expect(try isSmartCut(clip, from: source))
    }

    @Test func progressMovesForwardToCompletion() async throws {
        let source = try SmartCutFixtures.make(.matroskaH264)
        let folder = try TestMedia.makeTemporaryFolder()
        let request = ExportRequest(
            source: source, range: Self.range, mode: .precise,
            destination: folder.appendingPathComponent("clip.mkv"), estimatedSize: 1_000_000)
        var values: [Double] = []
        for try await value in Exporter().export(request) {
            values.append(value)
        }
        #expect(values.count > 2)
        #expect(values.last == 1)
        #expect(values == values.sorted())
    }

    @MainActor
    @Test(arguments: [Source.matroskaH264, .mp4H264])
    func cancellingLeavesNoFiles(_ fixture: Source) async throws {
        let source = try SmartCutFixtures.make(fixture)
        let checksum = try ExporterTests.checksum(of: source)
        let folder = try TestMedia.makeTemporaryFolder()
        let request = ExportRequest(
            source: source, range: Self.range, mode: .precise,
            destination: folder.appendingPathComponent("clip.\(fixture.fileExtension)"), estimatedSize: 1_000_000)
        let (workspaces, report) = AsyncStream<URL>.makeStream()
        // The head is encoded in a moment, so the copy is held until the consumer has cancelled.
        let gate = DispatchSemaphore(value: 0)
        let exporter = Exporter(
            workspaceObserver: { report.yield($0) },
            copyObserver: { _ in _ = gate.wait(timeout: .now() + 5) })

        let (started, signal) = AsyncStream<Void>.makeStream()
        let consumer = Task {
            for try await _ in exporter.export(request) {
                signal.finish()
            }
        }
        for await _ in started {}
        consumer.cancel()
        _ = await consumer.result
        gate.signal()

        var reported = workspaces.makeAsyncIterator()
        let workspace = try #require(await reported.next())
        #expect(await waitUntil { !FileManager.default.fileExists(atPath: workspace.path) })
        #expect(try ExporterTests.leftovers(in: folder).isEmpty)
        #expect(try ExporterTests.checksum(of: source) == checksum)
    }

    // The session passes HEVC samples through and hides what lies outside the range with an edit list.
    @Test func hevcInQuickTimeStaysWithTheExportSession() async throws {
        let source = try SmartCutFixtures.make(.mp4HEVC)
        let clip = try await export(source, content: .videoAndSound)
        try await expectFrames(of: clip, from: source, isQuickTime: true)
    }

    // MARK: Helpers

    /// The source frames a clip of `range` shows: timeline time 0 is the file's start, which in MPEG-TS
    /// is the sound's, a little before the first frame.
    private func shownFrames(of source: URL, in range: ClosedRange<TimeInterval>) throws -> Range<Int> {
        let report = try FFprobe.report(source)
        let offset = (try FFprobe.firstPacketTimes(source).first ?? 0) - report.format.start
        let rate = SmartCutFixtures.frameRate
        let tolerance = 0.000_5
        let first = Int(((range.lowerBound - offset) * rate + tolerance).rounded(.down))
        let end = Int(((range.upperBound - offset) * rate - tolerance).rounded(.up))
        return max(0, first)..<end
    }

    private func transcode(_ source: URL, range: ClosedRange<TimeInterval> = Self.range) throws -> URL {
        let container = ExportContainer.forSource(source, mode: .precise)
        let output = try TestMedia.makeTemporaryFolder().appendingPathComponent("clip.\(container.fileExtension)")
        _ = try Transcoder(source: source, container: container, mode: .precise)
            .export(range, to: output, isCancelled: { false }, progress: { _ in })
        return output
    }

    private func export(_ source: URL, content: ExportContent) async throws -> URL {
        let container = ExportContainer.forSource(source, mode: .precise, content: content)
        let folder = try TestMedia.makeTemporaryFolder()
        let destination = folder.appendingPathComponent("clip.\(container.fileExtension)")
        let request = ExportRequest(
            source: source, range: Self.range, mode: .precise, destination: destination, estimatedSize: 1_000_000,
            content: content)
        for try await _ in Exporter().export(request) {}
        return destination
    }

    /// Every frame of the clip is the source's frame at the same distance from the start, decoded without a
    /// complaint, and the clip is as long as asked.
    private func expectFrames(
        of clip: URL, from source: URL, range: ClosedRange<TimeInterval> = Self.range, isQuickTime: Bool
    ) async throws {
        #expect(try SmartCutFixtures.decodingErrors(of: clip) == "")
        let frames = try shownFrames(of: source, in: range)
        let expected = Array(try SmartCutFixtures.reds(of: source)[frames])
        let shown = try SmartCutFixtures.reds(of: clip)
        #expect(shown.count == expected.count)
        let mismatches = zip(shown, expected).enumerated().filter { abs($1.0 - $1.1) > Self.colorTolerance }
        #expect(mismatches.isEmpty, "frames \(mismatches.map(\.offset)) differ from the source")
        let length = Double(frames.count) / SmartCutFixtures.frameRate
        #expect(abs(try FFprobe.report(clip).format.seconds - length) < 0.1)
        // QuickTime files play in AVFoundation; the rest in the app's own player, through VideoToolbox.
        let decoded: [Double]
        if isQuickTime {
            let (reds, error) = try await SmartCutFixtures.avFoundationReds(of: clip)
            #expect(error == nil)
            decoded = reds
        } else {
            let result = try VideoToolboxDecoding.reds(of: clip)
            #expect(result.failures == 0)
            decoded = result.reds
        }
        #expect(decoded.count == expected.count)
        let differing = zip(decoded, expected).enumerated().filter { abs($1.0 - $1.1) > Self.colorTolerance * 2 }
        #expect(differing.isEmpty, "the system decoder shows frames \(differing.map(\.offset)) differently")
    }

    /// Both encoded and copied packets, and none hidden by an edit list, as an export session's pass-through
    /// would leave.
    private func isSmartCut(_ clip: URL, from source: URL) throws -> Bool {
        let (encoded, copied) = try packetOrigins(of: clip, in: source)
        let frames = try shownFrames(of: source, in: Self.range).count
        let packets = try SmartCutFixtures.videoPackets(of: clip).count
        return encoded > 0 && copied > 0 && packets == frames
    }

    /// How many of the clip's video packets were encoded anew, and how many are byte for byte the source's.
    private func packetOrigins(of clip: URL, in source: URL) throws -> (head: Int, copied: Int) {
        let sourcePackets = Set(try SmartCutFixtures.videoPackets(of: source).map(\.data))
        let clipPackets = try SmartCutFixtures.videoPackets(of: clip)
        let copied = clipPackets.count { sourcePackets.contains($0.data) }
        let keyframesCopied = clipPackets.count { packet in
            packet.isKeyframe && !sourcePackets.contains(packet.data)
                && sourcePackets.contains { $0.count < packet.data.count && packet.data.suffix($0.count) == $0 }
        }
        return (clipPackets.count - copied - keyframesCopied, copied)
    }
}
