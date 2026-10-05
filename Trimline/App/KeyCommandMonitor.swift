import AppKit
import TrimlineCore

/// Handles the single-key player shortcuts by physical key, so they work in any keyboard layout.
/// Runs before menu key equivalents; the matching menu items are there for discoverability.
@MainActor
final class KeyCommandMonitor {
    private enum KeyCode {
        static let space: UInt16 = 49
        static let letterI: UInt16 = 34
        static let letterO: UInt16 = 31
        static let letterL: UInt16 = 37
        static let comma: UInt16 = 43
        static let period: UInt16 = 47
        static let leftArrow: UInt16 = 123
        static let rightArrow: UInt16 = 124
        static let escape: UInt16 = 53
    }

    private static let handleCoarseNudge: TimeInterval = 1

    private let model: EditorModel
    private let interaction: InteractionState
    private var monitor: Any?

    init(model: EditorModel, interaction: InteractionState) {
        self.model = model
        self.interaction = interaction
    }

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let isHandled = MainActor.assumeIsolated { self?.handle(event) ?? false }
            return isHandled ? nil : event
        }
    }

    private func handle(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers.isDisjoint(with: [.command, .control, .option]), acceptsKeys(in: event.window) else {
            return false
        }
        let isShifted = modifiers.contains(.shift)
        let isFirstPress = !event.isARepeat

        switch event.keyCode {
        case KeyCode.space where focusedControlTakesSpace(in: event.window):
            // Straight to the control: the Play menu item would otherwise take Space first.
            event.window?.sendEvent(event)
        case KeyCode.space: if isFirstPress { model.togglePlayback() }
        case KeyCode.letterI: if isFirstPress { model.markStart() }
        case KeyCode.letterO: if isFirstPress { model.markEnd() }
        case KeyCode.letterL: if isFirstPress { model.toggleLooping() }
        case KeyCode.comma: model.step(frames: -1)
        case KeyCode.period: model.step(frames: 1)
        case KeyCode.leftArrow: moveHorizontally(direction: -1, coarse: isShifted)
        case KeyCode.rightArrow: moveHorizontally(direction: 1, coarse: isShifted)
        case KeyCode.escape where interaction.selectedHandle != nil: interaction.selectedHandle = nil
        default: return false
        }
        return true
    }

    private func acceptsKeys(in window: NSWindow?) -> Bool {
        guard let window, window === interaction.editorWindow, window.isKeyWindow, window.attachedSheet == nil,
            !(window.firstResponder is NSText), !interaction.isEditingText
        else { return false }
        return model.phase == .ready && model.saveState == .idle
    }

    // With Full Keyboard Access, Space presses the focused button or checkbox, as everywhere in macOS.
    private func focusedControlTakesSpace(in window: NSWindow?) -> Bool {
        guard NSApp.isFullKeyboardAccessEnabled, let control = window?.firstResponder as? NSControl else {
            return false
        }
        return control.canBecomeKeyView
    }

    private func moveHorizontally(direction: Int, coarse: Bool) {
        if let handle = interaction.selectedHandle {
            if coarse {
                model.nudge(handle, seconds: Double(direction) * Self.handleCoarseNudge)
            } else {
                model.nudge(handle, frames: direction)
            }
        } else if coarse {
            model.skip(by: Double(direction) * EditorModel.shortSkip)
        } else {
            model.step(frames: direction)
        }
    }
}
