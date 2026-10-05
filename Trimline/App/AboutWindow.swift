import AppKit
import SwiftUI

struct AboutWindow: Scene {
    static let id = "about"

    var body: some Scene {
        Window("About \(TrimlineApp.appName)", id: Self.id) {
            AboutView(app: .current, acknowledgements: Acknowledgements.all)
                .background(AboutWindowConfigurator())
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        // Keeps the window out of the Window menu; it opens from the app menu like the standard panel.
        .commandsRemoved()
    }
}

struct AppInfo {
    let name: String
    let version: String
    let build: String
    let copyright: String?

    @MainActor static var current: AppInfo {
        let bundle = Bundle.main
        return AppInfo(
            name: TrimlineApp.appName,
            version: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
            copyright: bundle.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String
        )
    }
}

// The standard About panel is neither minimized nor restored at the next launch, so this window isn't either.
private struct AboutWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        WindowObservingView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class WindowObservingView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.isRestorable = false
            window.styleMask.remove(.miniaturizable)
        }
    }
}
