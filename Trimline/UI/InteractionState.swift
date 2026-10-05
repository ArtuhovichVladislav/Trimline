import AppKit
import Observation
import SwiftUI
import TrimlineCore

/// Window state that belongs to the interface rather than the document: which trim handle the
/// arrow keys move, whether a text field is taking key presses, the timeline zoom, and whether
/// the editor window is the one receiving keys.
@MainActor
@Observable
final class InteractionState {
    var selectedHandle: EditorModel.TrimHandle?
    var isEditingText = false
    var viewport = TimelineViewport(duration: 0)
    /// Key and without a sheet or panel attached; single-key shortcuts work only then.
    private(set) var isEditorWindowKey = false
    @ObservationIgnored private(set) weak var editorWindow: NSWindow?
    /// Opens the editor window again after it was closed; set by the app's commands.
    @ObservationIgnored var showEditorWindow: (() -> Void)?

    func track(_ window: NSWindow?) {
        editorWindow = window
        refreshEditorWindowKey()
    }

    func refreshEditorWindowKey() {
        let isKey = editorWindow.map { $0.isKeyWindow && $0.attachedSheet == nil } ?? false
        if isEditorWindowKey != isKey {
            isEditorWindowKey = isKey
        }
    }
}

/// File actions the views trigger; the app layer decides how files are chosen and recorded.
struct FileActions: Sendable {
    var choose: @MainActor @Sendable () -> Void = {}
    var open: @MainActor @Sendable ([URL]) -> Void = { _ in }
}

extension EnvironmentValues {
    @Entry var fileActions = FileActions()
    /// Hands the window's undo manager to the app layer, which mirrors selection changes into it.
    @Entry var attachUndoManager: @MainActor @Sendable (UndoManager?) -> Void = { _ in }
}
