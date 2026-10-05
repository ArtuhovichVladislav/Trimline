import AppKit
import SwiftUI
import TrimlineCore

struct TrimlineCommands: Commands {
    let model: EditorModel
    let interaction: InteractionState
    let fileOpener: FileOpener

    @Environment(\.openWindow) private var openWindow

    private var isEditing: Bool {
        model.phase == .ready && model.saveState == .idle
    }

    // Menu key equivalents without modifiers would swallow typing in text fields, panels and other windows.
    private var acceptsSingleKeys: Bool {
        isEditing && interaction.isEditorWindowKey && !interaction.isEditingText
    }

    var body: some Commands {
        let _ = registerEditorWindowOpener()
        CommandGroup(replacing: .newItem) {
            Button("Open…") { fileOpener.chooseFile() }
                .keyboardShortcut("o")
                .disabled(!fileOpener.canOpen)
            recentFilesMenu
            // ⌘W stays with the window, which quits the app; ⌃⌘W is Xcode's Close File.
            Button("Close File") { model.closeCurrentFile() }
                .keyboardShortcut("w", modifiers: [.command, .control])
                .disabled(model.phase == .empty || model.saveState != .idle)
        }
        CommandGroup(before: .saveItem) {
            Button("Save Clip…") { model.prepareSave() }
                .keyboardShortcut("s")
                .disabled(!isEditing)
            Button(model.alwaysAsksForDestination ? "Save Frame…" : "Save Frame") { model.saveFrame() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(!model.canExportFrame)
        }
        CommandGroup(after: .pasteboard) {
            // ⌘C stays with text fields; the frame takes the shifted shortcut.
            Button("Copy Frame") { model.copyFrame(to: FramePasteboard.write) }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(!model.canExportFrame)
            Divider()
            Button("Set Clip Start") { model.markStart() }
                .keyboardShortcut("i", modifiers: [])
                .disabled(!acceptsSingleKeys)
            Button("Set Clip End") { model.markEnd() }
                .keyboardShortcut("o", modifiers: [])
                .disabled(!acceptsSingleKeys)
            Button("Reset Selection") { model.resetSelection() }
                .keyboardShortcut("r")
                .disabled(!isEditing)
        }
        // Without ToolbarCommands the toolbar group has no items to be placed before.
        CommandGroup(replacing: .toolbar) {
            zoomItems
        }
        CommandMenu("Playback") {
            playbackItems
        }
        CommandGroup(replacing: .help) {
            Button("\(TrimlineApp.appName) on GitHub") { ProjectLink.repository.open() }
            Button("Report a Problem…") { ProjectLink.newIssue.open() }
        }
    }

    // Lets a file opened from Finder bring the editor window back after it was closed.
    private func registerEditorWindowOpener() {
        let openWindow = openWindow
        interaction.showEditorWindow = { openWindow(id: TrimlineApp.editorWindowID) }
    }

    @ViewBuilder
    private var zoomItems: some View {
        Button("Zoom In") { interaction.viewport.zoomIn(around: model.currentTime) }
            .keyboardShortcut("+")
            .disabled(!isEditing || !interaction.viewport.canZoomIn)
        Button("Zoom Out") { interaction.viewport.zoomOut(around: model.currentTime) }
            .keyboardShortcut("-")
            .disabled(!isEditing || !interaction.viewport.canZoomOut)
        Button("Zoom to Fit") { interaction.viewport.zoomToFit() }
            .keyboardShortcut("0")
            .disabled(!isEditing || !interaction.viewport.canZoomOut)
    }

    private var recentFilesMenu: some View {
        Menu("Open Recent") {
            ForEach(fileOpener.recentFiles) { file in
                Button(file.title) { fileOpener.open([file.url]) }
                    .disabled(!fileOpener.canOpen)
            }
            Divider()
            Button("Clear Menu") { fileOpener.clearRecentFiles() }
                .disabled(fileOpener.recentFiles.isEmpty)
        }
    }

    @ViewBuilder
    private var playbackItems: some View {
        let playTitle: LocalizedStringKey = model.isPlaying ? "Pause" : "Play"
        Button(playTitle) { model.togglePlayback() }
            .keyboardShortcut(.space, modifiers: [])
            .disabled(!acceptsSingleKeys)
        Toggle("Loop Clip", isOn: Binding(get: { model.isLooping }, set: { _ in model.toggleLooping() }))
            .keyboardShortcut("l", modifiers: [])
            .disabled(!acceptsSingleKeys)
        Divider()
        Button("Previous Frame") { model.step(frames: -1) }
            .keyboardShortcut(.leftArrow, modifiers: [])
            .disabled(!acceptsSingleKeys)
        Button("Next Frame") { model.step(frames: 1) }
            .keyboardShortcut(.rightArrow, modifiers: [])
            .disabled(!acceptsSingleKeys)
        Button("Back 1 Second") { model.skip(by: -EditorModel.shortSkip) }
            .keyboardShortcut(.leftArrow, modifiers: .shift)
            .disabled(!acceptsSingleKeys)
        Button("Forward 1 Second") { model.skip(by: EditorModel.shortSkip) }
            .keyboardShortcut(.rightArrow, modifiers: .shift)
            .disabled(!acceptsSingleKeys)
    }
}

private enum ProjectLink: String {
    case repository = "https://github.com/ArtuhovichVladislav/Trimline"
    case newIssue = "https://github.com/ArtuhovichVladislav/Trimline/issues/new"

    @MainActor func open() {
        guard let url = URL(string: rawValue) else { return }
        NSWorkspace.shared.open(url)
    }
}
