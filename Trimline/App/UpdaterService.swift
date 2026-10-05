import Foundation
import Observation
import Sparkle

/// Sparkle's standard updater. The appcast request is the app's only network access.
@MainActor
@Observable
final class UpdaterService {
    /// Debug builds never start Sparkle, so they don't check the release feed; nor do builds without
    /// a real EdDSA key (see docs/release.md), where Sparkle would show a configuration error at launch.
    let isAvailable: Bool
    private(set) var canCheckForUpdates = false

    // Sparkle's own alerts change these too; the observations below bring the changes back.
    var automaticallyChecksForUpdates: Bool {
        didSet {
            if updater.automaticallyChecksForUpdates != automaticallyChecksForUpdates {
                updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates
            }
        }
    }

    var automaticallyDownloadsUpdates: Bool {
        didSet {
            if updater.automaticallyDownloadsUpdates != automaticallyDownloadsUpdates {
                updater.automaticallyDownloadsUpdates = automaticallyDownloadsUpdates
            }
        }
    }

    @ObservationIgnored private let controller: SPUStandardUpdaterController
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []

    private var updater: SPUUpdater { controller.updater }

    init(bundle: Bundle = .main) {
        let controller = SPUStandardUpdaterController(
            startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil
        )
        self.controller = controller
        #if DEBUG
            isAvailable = false
        #else
            isAvailable = Self.hasPublicKey(in: bundle)
        #endif
        automaticallyChecksForUpdates = controller.updater.automaticallyChecksForUpdates
        automaticallyDownloadsUpdates = controller.updater.automaticallyDownloadsUpdates
    }

    func start() {
        guard isAvailable, observations.isEmpty else { return }
        observations = [
            updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
                MainActor.assumeIsolated { self?.canCheckForUpdates = updater.canCheckForUpdates }
            },
            updater.observe(\.automaticallyChecksForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
                MainActor.assumeIsolated { self?.syncChecks(updater.automaticallyChecksForUpdates) }
            },
            updater.observe(\.automaticallyDownloadsUpdates, options: [.initial, .new]) { [weak self] updater, _ in
                MainActor.assumeIsolated { self?.syncDownloads(updater.automaticallyDownloadsUpdates) }
            },
        ]
        controller.startUpdater()
    }

    private func syncChecks(_ value: Bool) {
        if automaticallyChecksForUpdates != value {
            automaticallyChecksForUpdates = value
        }
    }

    private func syncDownloads(_ value: Bool) {
        if automaticallyDownloadsUpdates != value {
            automaticallyDownloadsUpdates = value
        }
    }

    func checkForUpdates() {
        updater.checkForUpdates()
    }

    private static func hasPublicKey(in bundle: Bundle) -> Bool {
        guard let key = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String else { return false }
        return Data(base64Encoded: key)?.count == ed25519PublicKeyLength
    }

    private static let ed25519PublicKeyLength = 32
}
