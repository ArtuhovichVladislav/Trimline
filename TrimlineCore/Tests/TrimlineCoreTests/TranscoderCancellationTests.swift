import Foundation
import Testing

@testable import TrimlineCore

@MainActor
@Suite(.serialized, .enabled(if: ExternalFFmpeg.isAvailable)) struct TranscoderCancellationTests {
    private static let gateTimeout: TimeInterval = 5

    @Test(arguments: [TranscodeFixtures.Source.webmVP9, .matroskaH264])
    func cancellingLeavesNoFiles(_ fixture: TranscodeFixtures.Source) async throws {
        let source = try TranscodeFixtures.make(fixture)
        let checksum = try ExporterTests.checksum(of: source)
        let container = ExportContainer.forSource(source, mode: .precise)
        let folder = try TestMedia.makeTemporaryFolder()
        let request = ExportRequest(
            source: source, range: 0...Double(TranscodeFixtures.duration), mode: .precise,
            destination: folder.appendingPathComponent("clip.\(container.fileExtension)"), estimatedSize: 1_000_000)
        let (workspaces, report) = AsyncStream<URL>.makeStream()
        // A short clip encodes in a moment, so the encoder is held until the consumer has cancelled.
        let gate = DispatchSemaphore(value: 0)
        let timeout = Self.gateTimeout
        let exporter = Exporter(
            workspaceObserver: { report.yield($0) },
            copyObserver: { _ in _ = gate.wait(timeout: .now() + timeout) })

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
}
