import Foundation
import os

typealias ExportProgress = @Sendable (Double) -> Void

public actor Exporter {
    static let progressInterval: Duration = .milliseconds(100)
    private static let activityReason = "Saving a trimmed clip"

    // Lets tests see the temporary folder: listing the system's TemporaryItems folder is not permitted.
    private let workspaceObserver: (@Sendable (URL) -> Void)?
    // Lets tests hold an FFmpeg copy or transcode mid-way; it is called on the working thread.
    let copyObserver: (@Sendable (Double) -> Void)?
    private let runningExports = OSAllocatedUnfairLock(initialState: 0)
    private static let idlePollInterval: Duration = .milliseconds(50)

    public init() {
        workspaceObserver = nil
        copyObserver = nil
    }

    init(
        workspaceObserver: @escaping @Sendable (URL) -> Void,
        copyObserver: (@Sendable (Double) -> Void)? = nil
    ) {
        self.workspaceObserver = workspaceObserver
        self.copyObserver = copyObserver
    }

    public nonisolated func export(_ request: ExportRequest) -> AsyncThrowingStream<Double, any Error> {
        let (stream, continuation) = AsyncThrowingStream<Double, any Error>.makeStream()
        let cancellation = ExportCancellation()
        // The export task is not cancelled itself: it has to keep running to stop the writer
        // and delete the temporary file after the consumer has gone.
        continuation.onTermination = { termination in
            if case .cancelled = termination {
                cancellation.cancel()
            }
        }
        runningExports.withLock { $0 += 1 }
        Task {
            await self.run(request, cancellation: cancellation, continuation: continuation)
            self.runningExports.withLock { $0 -= 1 }
        }
        return stream
    }

    /// Returns once every export, including cancelled ones still deleting their temporary files, has ended.
    public nonisolated func waitUntilIdle() async {
        while runningExports.withLock({ $0 > 0 }), !Task.isCancelled {
            try? await Task.sleep(for: Self.idlePollInterval)
        }
    }

    private func run(
        _ request: ExportRequest,
        cancellation: ExportCancellation,
        continuation: AsyncThrowingStream<Double, any Error>.Continuation
    ) async {
        let activity = ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: Self.activityReason)
        defer { ProcessInfo.processInfo.endActivity(activity) }

        let reporter = ProgressReporter(continuation: continuation)
        do throws(ExportError) {
            try await perform(request, cancellation: cancellation, progress: reporter.report)
            reporter.report(1)
            continuation.finish()
        } catch {
            continuation.finish(throwing: error)
        }
    }

    private func perform(
        _ request: ExportRequest,
        cancellation: ExportCancellation,
        progress: @escaping ExportProgress
    ) async throws(ExportError) {
        let workspace = try ExportWorkspace.prepare(for: request)
        defer { workspace.remove() }
        workspaceObserver?(workspace.directory)
        progress(0)

        let container = await Self.container(for: request)
        if await usesAssetExport(request, container: container) {
            try await exportAsset(request, to: workspace.fileURL, cancellation: cancellation, progress: progress)
        } else {
            try await writeWithFFmpeg(
                request, container: container, to: workspace.fileURL, cancellation: cancellation, progress: progress)
        }
        guard !cancellation.isCancelled else { throw .cancelled }
        try workspace.publish()
    }
}

final class ExportCancellation: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: false)

    var isCancelled: Bool { state.withLock { $0 } }

    func cancel() {
        state.withLock { $0 = true }
    }
}

// Writers report raw values; the stream only ever moves forward and stays within 0...1.
private final class ProgressReporter: Sendable {
    private let continuation: AsyncThrowingStream<Double, any Error>.Continuation
    private let last = OSAllocatedUnfairLock(initialState: -1.0)

    init(continuation: AsyncThrowingStream<Double, any Error>.Continuation) {
        self.continuation = continuation
    }

    @Sendable func report(_ value: Double) {
        let clamped = value.clamped(to: 0...1)
        let isNew = last.withLock { last in
            guard clamped > last else { return false }
            last = clamped
            return true
        }
        if isNew {
            continuation.yield(clamped)
        }
    }
}
