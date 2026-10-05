import AppKit
import TrimlineCore
import UniformTypeIdentifiers

@MainActor
enum FilePanels {
    /// Shows audio and video by default; the content decides, so any file can still be picked.
    static func chooseMediaFile() async -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        let filter = ContentFilterAccessory(panel: panel)
        panel.accessoryView = filter.view
        panel.isAccessoryViewDisclosed = true

        let response = await present(panel, attachedTo: nil)
        return withExtendedLifetime(filter) { response == .OK ? panel.url : nil }
    }

    static func chooseDestination(
        for proposal: SaveProposal, named name: String? = nil, attachedTo window: NSWindow?
    ) async -> URL? {
        let panel = NSSavePanel()
        panel.title = String(localized: "Save Clip")
        panel.nameFieldStringValue = name ?? proposal.destination.lastPathComponent
        if proposal.folderIsWritable {
            panel.directoryURL = proposal.destination.deletingLastPathComponent()
        } else {
            panel.message = String(localized: "The original file’s folder is read-only. Choose where to save the clip.")
        }
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        if let type = UTType(filenameExtension: proposal.destination.pathExtension) {
            panel.allowedContentTypes = [type]
        }
        let response = await present(panel, attachedTo: window)
        return response == .OK ? panel.url : nil
    }

    static func chooseFrameDestination(for proposal: FrameSaveProposal, attachedTo window: NSWindow?) async -> URL? {
        let panel = NSSavePanel()
        panel.title = String(localized: "Save Frame")
        panel.nameFieldStringValue = proposal.destination.lastPathComponent
        if proposal.folderIsWritable {
            panel.directoryURL = proposal.destination.deletingLastPathComponent()
        } else {
            panel.message = String(
                localized: "The original file’s folder is read-only. Choose where to save the frame.")
        }
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.allowedContentTypes = [.png]
        let response = await present(panel, attachedTo: window)
        return response == .OK ? panel.url : nil
    }

    private static func present(_ panel: NSSavePanel, attachedTo window: NSWindow?) async -> NSApplication.ModalResponse
    {
        await withCheckedContinuation { continuation in
            if let window {
                panel.beginSheetModal(for: window) { continuation.resume(returning: $0) }
            } else {
                panel.begin { continuation.resume(returning: $0) }
            }
        }
    }
}

@MainActor
private final class ContentFilterAccessory: NSObject {
    private static let insets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
    private static let audiovisualIndex = 0

    let view: NSView
    private weak var panel: NSOpenPanel?
    private let popUp = NSPopUpButton(frame: .zero, pullsDown: false)

    init(panel: NSOpenPanel) {
        self.panel = panel
        popUp.addItems(withTitles: [String(localized: "Audio and Video"), String(localized: "All Files")])
        let label = NSTextField(labelWithString: String(localized: "Show:"))
        let stack = NSStackView(views: [label, popUp])
        stack.edgeInsets = Self.insets
        stack.frame.size = stack.fittingSize
        view = stack
        super.init()
        popUp.target = self
        popUp.action = #selector(filterChanged)
        applyFilter()
    }

    @objc private func filterChanged() {
        applyFilter()
    }

    private func applyFilter() {
        panel?.allowedContentTypes = popUp.indexOfSelectedItem == Self.audiovisualIndex ? [.audiovisualContent] : []
    }
}
