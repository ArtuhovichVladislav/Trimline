import AppKit
import TrimlineCore

/// Asks before opening a file from Finder or quitting stops the clip being saved.
@MainActor
enum SaveInterruption {
    enum Reason {
        case opening(URL)
        case quitting
    }

    private static let escape = "\u{1b}"

    static func confirm(_ reason: Reason) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        switch reason {
        case .opening(let url):
            alert.messageText = String(
                localized: "Stop saving and open “\(url.lastPathComponent)”?",
                comment: "Alert when a file is opened from Finder while a clip is being saved")
        case .quitting:
            alert.messageText = String(localized: "Stop saving and quit?")
        }
        alert.informativeText = String(localized: "The clip isn’t finished and won’t be saved.")
        alert.addButton(withTitle: String(localized: "Stop Saving"))
        alert.addButton(withTitle: String(localized: "Continue Saving")).keyEquivalent = escape
        return alert.runModal() == .alertFirstButtonReturn
    }
}

extension EditorModel {
    var isSavingClip: Bool {
        if case .saving = saveState { return true }
        return false
    }
}
