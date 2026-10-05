import SwiftUI

@main
struct TrimlineApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    // The app name is never translated, so it is kept out of the string catalog.
    static let appName = "Trimline"
    static let editorWindowID = "main"
    private static let defaultWindowSize = CGSize(width: 560, height: 360)

    var body: some Scene {
        Window(Self.appName, id: Self.editorWindowID) {
            MainView()
                .environment(appDelegate.model)
                .environment(appDelegate.interaction)
                .environment(\.fileActions, appDelegate.fileActions)
                .environment(\.attachUndoManager, appDelegate.selectionUndo.attach)
                .toolbarBackground(.hidden, for: .windowToolbar)
        }
        .defaultSize(Self.defaultWindowSize)
        .windowResizability(.contentSize)
        .commands {
            TrimlineCommands(
                model: appDelegate.model,
                interaction: appDelegate.interaction,
                fileOpener: appDelegate.fileOpener
            )
            UpdateCommands(updater: appDelegate.updater)
        }
        Settings {
            SettingsView()
                .environment(appDelegate.updater)
        }
        AboutWindow()
    }
}
