import AppKit
import TrimlineCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    // Created with the delegate rather than the window, so files that arrive at launch
    // (Finder, Dock, `open -a`, the service) open straight into the player.
    let model: EditorModel
    let interaction: InteractionState
    let fileOpener: FileOpener
    let fileActions: FileActions
    let selectionUndo: SelectionUndo
    let updater = UpdaterService()
    private let exporter: Exporter
    private let keyCommands: KeyCommandMonitor
    private let settingsSync: SettingsSync

    // Long enough to delete a cancelled clip's temporary file, short enough not to hold up quitting.
    private static let exportCleanupLimit: Duration = .seconds(5)

    override init() {
        let exporter = Exporter()
        let model = EditorModel(
            clipSuffix: AppSettings.clipSuffix, exporter: exporter, selectionMemory: SelectionStore())
        model.frameNaming = FrameNaming(word: AppSettings.frameWord)
        let interaction = InteractionState()
        let fileOpener = FileOpener(model: model, interaction: interaction)
        self.exporter = exporter
        self.model = model
        self.interaction = interaction
        self.fileOpener = fileOpener
        self.fileActions = FileActions(
            choose: { fileOpener.chooseFile() },
            open: { fileOpener.open($0) }
        )
        self.keyCommands = KeyCommandMonitor(model: model, interaction: interaction)
        self.selectionUndo = SelectionUndo(model: model)
        self.settingsSync = SettingsSync(model: model)
        super.init()
        settingsSync.start()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
        keyCommands.start()
        HangMonitor.start()
        updater.start()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        fileOpener.openFromOutside(urls)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    // The selection is written a moment after the last change; quitting right after a drag must not lose it.
    // A stopped save is given time to delete its incomplete file.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if model.isSavingClip {
            guard SaveInterruption.confirm(.quitting) else { return .terminateCancel }
            model.cancelSave()
        }
        Task {
            await waitForExportCleanup()
            await model.rememberSelectionNow()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    private func waitForExportCleanup() async {
        let exporter = exporter
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await exporter.waitUntilIdle() }
            group.addTask { try? await Task.sleep(for: Self.exportCleanupLimit) }
            await group.next()
            group.cancelAll()
        }
    }

    // Selector `trimFiles:userData:error:` is declared under NSServices in Info.plist.
    @objc func trimFiles(
        _ pboard: NSPasteboard,
        userData: String,
        error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let urls = pboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
        guard !urls.isEmpty else {
            error.pointee = String(localized: "No files were passed to Trimline.") as NSString
            return
        }
        NSApp.activate()
        fileOpener.openFromOutside(urls)
    }
}
