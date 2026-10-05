import Foundation
import TrimlineCore

/// Mirrors the model's selection history into the window's undo manager, so Edit ▸ Undo and Redo,
/// their titles and ⌘Z work as usual, and a text field being edited keeps its own typing undo.
@MainActor
final class SelectionUndo {
    private let model: EditorModel
    private weak var undoManager: UndoManager?

    private static var actionName: String {
        String(localized: "Selection Change", comment: "Undo action: Edit ▸ Undo Selection Change")
    }

    init(model: EditorModel) {
        self.model = model
        model.onHistoryChange = { [weak self] change in
            self?.historyChanged(change)
        }
    }

    func attach(_ manager: UndoManager?) {
        guard manager !== undoManager else { return }
        undoManager?.removeAllActions(withTarget: self)
        undoManager = manager
        manager?.levelsOfUndo = model.history.limit
    }

    private func historyChanged(_ change: SelectionHistory.Change) {
        switch change {
        case .recorded: register { $0.undo() }
        case .cleared: undoManager?.removeAllActions(withTarget: self)
        }
    }

    private func undo() {
        model.undo()
        register { $0.redo() }
    }

    private func redo() {
        model.redo()
        register { $0.undo() }
    }

    // Registered while the manager is undoing, an action lands on its redo stack.
    private func register(_ action: @escaping @MainActor (SelectionUndo) -> Void) {
        undoManager?.registerUndo(withTarget: self, handler: action)
        undoManager?.setActionName(Self.actionName)
    }
}
