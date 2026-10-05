import AppKit
import Observation
import TrimlineCore

/// The single route for every way of opening a file, so Open Recent sees them all.
@MainActor
@Observable
final class FileOpener {
    struct RecentFile: Identifiable {
        let url: URL
        let title: String
        var id: URL { url }
    }

    static let recentFileLimit = 10

    private(set) var recentFiles: [RecentFile] = []

    @ObservationIgnored private let model: EditorModel
    @ObservationIgnored private let interaction: InteractionState
    @ObservationIgnored private let documents = NSDocumentController.shared
    @ObservationIgnored private var isChoosingFile = false
    @ObservationIgnored private var isAskingToStopSaving = false
    @ObservationIgnored private var recordTask: Task<Void, Never>?

    init(model: EditorModel, interaction: InteractionState) {
        self.model = model
        self.interaction = interaction
        refreshRecentFiles()
    }

    /// Opening from inside the app is unavailable while a clip is being saved.
    var canOpen: Bool { !model.isSavingClip }

    func open(_ urls: [URL]) {
        let files = urls.filter(\.isFileURL)
        guard let first = files.first, canOpen else { return }
        model.open(files)
        recordWhenOpened(first)
    }

    /// Finder, the Dock and the service: asks before stopping a save, and brings the editor window back.
    func openFromOutside(_ urls: [URL]) {
        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty else { return }
        if model.isSavingClip {
            // Asked after the Apple event or service call returns, so the sender isn't kept waiting.
            Task { askToStopSaving(thenOpen: files) }
        } else {
            openInEditor(files)
        }
    }

    func chooseFile() {
        guard !isChoosingFile, canOpen else { return }
        isChoosingFile = true
        Task {
            let url = await FilePanels.chooseMediaFile()
            isChoosingFile = false
            if let url {
                open([url])
            }
        }
    }

    func clearRecentFiles() {
        documents.clearRecentDocuments(nil)
        refreshRecentFiles()
        model.forgetRememberedSelections()
    }

    private func askToStopSaving(thenOpen files: [URL]) {
        guard let first = files.first, !isAskingToStopSaving else { return }
        guard model.isSavingClip else { return openInEditor(files) }
        isAskingToStopSaving = true
        let stops = SaveInterruption.confirm(.opening(first))
        isAskingToStopSaving = false
        guard stops else { return }
        model.cancelSave()
        openInEditor(files)
    }

    private func openInEditor(_ files: [URL]) {
        open(files)
        interaction.showEditorWindow?()
    }

    // Open Recent lists only files that actually opened.
    private func recordWhenOpened(_ url: URL) {
        recordTask?.cancel()
        recordTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                switch model.phase {
                case .loading:
                    await phaseChange()
                case .ready:
                    documents.noteNewRecentDocumentURL(url)
                    refreshRecentFiles()
                    return
                case .empty, .failed:
                    return
                }
            }
        }
    }

    private func phaseChange() async {
        await withCheckedContinuation { continuation in
            withObservationTracking {
                _ = model.phase
            } onChange: {
                continuation.resume()
            }
        }
    }

    // Like Finder, files with the same name show their folder too.
    private func refreshRecentFiles() {
        let urls = documents.recentDocumentURLs.prefix(Self.recentFileLimit)
        let names = urls.map(\.lastPathComponent)
        recentFiles = urls.map { url in
            let name = url.lastPathComponent
            guard names.filter({ $0 == name }).count > 1 else { return RecentFile(url: url, title: name) }
            let folder = url.deletingLastPathComponent().lastPathComponent
            return RecentFile(url: url, title: "\(name) — \(folder)")
        }
    }
}
