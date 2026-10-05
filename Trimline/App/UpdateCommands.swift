import SwiftUI

/// About and Check for Updates share one group: an item placed after a group that another scene
/// replaces is dropped from the menu.
struct UpdateCommands: Commands {
    let updater: UpdaterService

    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About \(TrimlineApp.appName)") { openWindow(id: AboutWindow.id) }
            Button("Check for Updates…") { updater.checkForUpdates() }
                .disabled(!updater.canCheckForUpdates)
        }
    }
}
