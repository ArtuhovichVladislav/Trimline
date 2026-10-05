import AppKit
import SwiftUI

/// Tells `InteractionState` which window is the editor and keeps `isEditorWindowKey` current.
struct EditorWindowTracker: NSViewRepresentable {
    let interaction: InteractionState

    func makeNSView(context: Context) -> NSView {
        TrackingView(interaction: interaction)
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class TrackingView: NSView {
        private static let notifications: [Notification.Name] = [
            NSWindow.didBecomeKeyNotification,
            NSWindow.didResignKeyNotification,
            NSWindow.willBeginSheetNotification,
            NSWindow.didEndSheetNotification,
            NSWindow.willCloseNotification,
        ]

        private let interaction: InteractionState
        private var observers: [NSObjectProtocol] = []
        private weak var trackedWindow: NSWindow?

        init(interaction: InteractionState) {
            self.interaction = interaction
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not supported")
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else {
                // A reopened window's new view may have registered before this one leaves.
                if interaction.editorWindow === trackedWindow {
                    interaction.track(nil)
                }
                return
            }
            trackedWindow = window
            interaction.track(window)
            observers = Self.notifications.map { name in
                NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) {
                    [weak self] notification in
                    let isClosing = notification.name == NSWindow.willCloseNotification
                    MainActor.assumeIsolated { self?.windowChanged(isClosing: isClosing) }
                }
            }
        }

        private func windowChanged(isClosing: Bool) {
            if isClosing {
                if interaction.editorWindow === trackedWindow {
                    interaction.track(nil)
                }
            } else {
                interaction.refreshEditorWindowKey()
            }
        }
    }
}
