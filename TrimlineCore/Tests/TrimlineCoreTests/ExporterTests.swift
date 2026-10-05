import AVFoundation
import CryptoKit
import Foundation
import Testing

@testable import TrimlineCore

@Suite(.serialized) struct ExporterTests {
    private static let gopVideo = TestMedia.VideoSpec(duration: 4, frameRate: 30, keyframeInterval: 30)
    private static let gopLength: TimeInterval = 1
    private static let audioTolerance: TimeInterval = 0.1
    private static let editListTolerance: TimeInterval = 0.03
    private static let preciseTolerance: TimeInterval = 0.1
    private static let estimatedSize: Int64 = 1_000_000

    // MARK: Fast mode

    @Test(arguments: [AVFileType.mov, .mp4])
    func fastVideoKeepsTracksAndSource(_ fileType: AVFileType) async throws {
        var spec = Self.gopVideo
        spec.fileType = fileType
        let source = try await TestMedia.video(spec)
        let clip = try await exportAndVerify(source, range: 1.5...3)
        #expect(clip.duration <= 1.5 + Self.gopLength + Self.audioTolerance)
        #expect(clip.duration >= 1.5 - Self.audioTolerance)
    }

    @Test(arguments: [AVFileType.m4a, .wav])
    func fastAudioCutsAtSelection(_ fileType: AVFileType) async throws {
        let source = try await TestMedia.audio(.init(fileType: fileType))
        let clip = try await exportAndVerify(source, range: 0.5...2)
        // M4A hides the audio before the cut with an edit list; WAV starts on the packet holding it.
        #expect(abs(clip.duration - 1.5) < (fileType == .m4a ? Self.editListTolerance : Self.audioTolerance))
    }

    @Test func preciseVideoIsExact() async throws {
        let source = try await TestMedia.video(Self.gopVideo)
        let clip = try await exportAndVerify(source, range: 1.5...3, mode: .precise)
        #expect(abs(clip.duration - 1.5) < Self.preciseTolerance)
    }

    @Test(.enabled(if: ExternalFFmpeg.isAvailable)) func preciseCopiesAudioOnlyFFmpegReads() async throws {
        let source = try RemuxFixtures.make(.ogg)
        let request = try makeRequest(source, range: 1...2, mode: .precise)
        try await drain(request)
        #expect(abs(try FFprobe.report(request.destination).format.seconds - 1) < Self.audioTolerance)
    }

    @Test func progressMovesForwardToCompletion() async throws {
        let source = try await TestMedia.video(Self.gopVideo)
        let request = try makeRequest(source, range: 0...4)
        var values: [Double] = []
        for try await value in Exporter().export(request) {
            values.append(value)
        }
        #expect(values.last == 1)
        #expect(values == values.sorted())
        #expect(values.allSatisfy { (0...1).contains($0) })
    }

    // MARK: Refusals

    @Test func neverOverwritesExistingFile() async throws {
        let source = try await TestMedia.audio()
        let request = try makeRequest(source, range: 0...1)
        let existing = Data("keep me".utf8)
        try existing.write(to: request.destination)

        await #expect(throws: ExportError.destinationExists) { try await drain(request) }
        #expect(try Data(contentsOf: request.destination) == existing)
    }

    @Test func refusesMissingFolder() async throws {
        let source = try await TestMedia.audio()
        let folder = try TestMedia.makeTemporaryFolder().appendingPathComponent("missing", isDirectory: true)
        let request = ExportRequest(
            source: source, range: 0...1, mode: .fast,
            destination: folder.appendingPathComponent("clip.wav"), estimatedSize: Self.estimatedSize
        )
        await #expect(throws: ExportError.destinationNotWritable) { try await drain(request) }
    }

    @Test(arguments: [Int64.max, Int64.max / 2])
    func refusesWhenDiskIsTooSmall(_ size: Int64) async throws {
        let source = try await TestMedia.audio()
        let base = try makeRequest(source, range: 0...1)
        let request = ExportRequest(
            source: source, range: base.range, mode: .fast, destination: base.destination, estimatedSize: size
        )
        await #expect {
            try await drain(request)
        } throws: { error in
            guard case ExportError.insufficientDiskSpace(let required, let available) = error else { return false }
            return required >= size && available < required
        }
        #expect(!FileManager.default.fileExists(atPath: request.destination.path))
    }

    @Test func rejectsUnknownContainer() async throws {
        let source = try TestMedia.garbage(extension: "xyz")
        let request = try makeRequest(source, range: 0...1)
        await #expect(throws: ExportError.unsupportedFormat) { try await drain(request) }
        #expect(!FileManager.default.fileExists(atPath: request.destination.path))
    }

    // MARK: Helpers

    struct Clip {
        let url: URL
        let duration: TimeInterval
    }

    private func exportAndVerify(
        _ source: URL, range: ClosedRange<TimeInterval>, mode: ExportMode = .fast
    ) async throws -> Clip {
        let checksum = try Self.checksum(of: source)
        let request = try makeRequest(source, range: range, mode: mode)
        try await drain(request)

        #expect(try Self.checksum(of: source) == checksum)
        let clip = AVURLAsset(url: request.destination)
        let sourceTracks = try await AVURLAsset(url: source).load(.tracks)
        #expect(try await clip.load(.tracks).count == sourceTracks.count)
        #expect(
            try Self.leftovers(in: request.destination.deletingLastPathComponent()) == [
                request.destination.lastPathComponent
            ])
        return Clip(url: request.destination, duration: try await clip.load(.duration).seconds)
    }

    static func checksum(of url: URL) throws -> SHA256.Digest {
        SHA256.hash(data: try Data(contentsOf: url, options: .mappedIfSafe))
    }

    static func leftovers(in folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    }
}

func makeRequest(
    _ source: URL, range: ClosedRange<TimeInterval>, mode: ExportMode = .fast
) throws -> ExportRequest {
    let folder = try TestMedia.makeTemporaryFolder()
    let name = "clip-\(UUID().uuidString).\(source.pathExtension)"
    return ExportRequest(
        source: source, range: range, mode: mode,
        destination: folder.appendingPathComponent(name), estimatedSize: 1_000_000
    )
}

func drain(_ request: ExportRequest) async throws {
    for try await _ in Exporter().export(request) {}
}
