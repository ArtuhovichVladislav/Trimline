import SwiftUI

struct UpdateSettingsSection: View {
    @Environment(UpdaterService.self) private var updater

    var body: some View {
        @Bindable var updater = updater
        Section("Updates") {
            Toggle("Automatically check for updates", isOn: $updater.automaticallyChecksForUpdates)
            Toggle("Automatically download and install updates", isOn: $updater.automaticallyDownloadsUpdates)
                .disabled(!updater.automaticallyChecksForUpdates)
        }
        .disabled(!updater.isAvailable)
    }
}
