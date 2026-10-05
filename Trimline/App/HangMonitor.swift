import Foundation
import os

#if DEBUG
    /// Logs every main-thread stall longer than `threshold` by timing how late a queued probe runs.
    enum HangMonitor {
        private static let threshold: Duration = .milliseconds(100)
        private static let probeInterval: DispatchTimeInterval = .milliseconds(50)
        private static let queue = DispatchQueue(label: "Trimline.HangMonitor", qos: .utility)
        private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Trimline", category: "hangs")

        static func start() {
            scheduleProbe()
        }

        private static func scheduleProbe() {
            queue.asyncAfter(deadline: .now() + probeInterval) {
                let sentAt = ContinuousClock.now
                DispatchQueue.main.async {
                    let delay = ContinuousClock.now - sentAt
                    if delay >= threshold {
                        let milliseconds = Int(delay / .milliseconds(1))
                        logger.warning("Main thread was blocked for \(milliseconds, privacy: .public) ms")
                    }
                    scheduleProbe()
                }
            }
        }
    }
#else
    import MetricKit

    /// Writes the hang reports MetricKit delivers (at most daily, for the previous day) to the app's log.
    enum HangMonitor {
        private static let reporter = HangReporter()

        static func start() {
            MXMetricManager.shared.add(reporter)
        }
    }

    private final class HangReporter: NSObject, MXMetricManagerSubscriber, Sendable {
        private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Trimline", category: "hangs")

        func didReceive(_ payloads: [MXDiagnosticPayload]) {
            for hang in payloads.flatMap({ $0.hangDiagnostics ?? [] }) {
                let duration = hang.hangDuration.converted(to: .milliseconds).value
                let stack = String(decoding: hang.callStackTree.jsonRepresentation(), as: UTF8.self)
                logger.error("Hang of \(Int(duration), privacy: .public) ms: \(stack, privacy: .public)")
            }
        }
    }
#endif
