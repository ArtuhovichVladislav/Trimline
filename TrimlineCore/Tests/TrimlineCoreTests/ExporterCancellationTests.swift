import Foundation
import Testing

@testable import TrimlineCore

@MainActor
@Suite(.serialized) struct ExporterCancellationTests {
    // Long enough that the export is still running when the consumer cancels.
    private static let longVideo = TestMedia.VideoSpec(duration: 20)
    private static let gateTimeout: TimeInterval = 5

    @Test(arguments: [ExportMode.precise, .fast])
    func cancellingLeavesNoFiles(_ mode: ExportMode) async throws {
        let source = try await TestMedia.video(Self.longVideo)
        let checksum = try ExporterTests.checksum(of: source)
        let request = try makeRequest(source, range: 0...Self.longVideo.duration, mode: mode)
        let (workspaces, report) = AsyncStream<URL>.makeStream()
        // A stream copy of this file takes milliseconds, so it is held until the consumer has cancelled.
        let gate = DispatchSemaphore(value: 0)
        let timeout = Self.gateTimeout
        let hold: @Sendable (Double) -> Void = { _ in _ = gate.wait(timeout: .now() + timeout) }
        let exporter = Exporter(workspaceObserver: { report.yield($0) }, copyObserver: mode == .fast ? hold : nil)

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
        try await Task.sleep(for: .milliseconds(300))
        #expect(try ExporterTests.leftovers(in: request.destination.deletingLastPathComponent()).isEmpty)
        #expect(try ExporterTests.checksum(of: source) == checksum)
    }
}
