import SwiftUI
import TrimlineCore

struct MainView: View {
    private enum Metrics {
        static let minWidth: CGFloat = 480
        static let idealWidth: CGFloat = 560
        static let maxWidth: CGFloat = 1200
        static let sidePadding: CGFloat = 18
        static let topPadding: CGFloat = 6
        static let hintSpacing: CGFloat = 12
    }

    @Environment(EditorModel.self) private var model
    @Environment(InteractionState.self) private var interaction
    @Environment(\.fileActions) private var fileActions
    @Environment(\.undoManager) private var undoManager
    @Environment(\.attachUndoManager) private var attachUndoManager
    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: Metrics.hintSpacing) {
            content
            if model.requestedFileCount > 1 {
                Text("Opened 1 of \(model.requestedFileCount) files")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding([.horizontal, .bottom], Metrics.sidePadding)
        .padding(.top, Metrics.topPadding)
        .frame(minWidth: Metrics.minWidth, idealWidth: Metrics.idealWidth, maxWidth: Metrics.maxWidth)
        .fixedSize(horizontal: false, vertical: true)
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard !files.isEmpty, !model.isSavingClip else { return false }
            fileActions.open(files)
            return true
        } isTargeted: {
            isDropTargeted = $0 && !model.isSavingClip
        }
        .background(EditorWindowTracker(interaction: interaction))
        .sheet(isPresented: .constant(model.saveState != .idle)) {
            SaveSheet()
        }
        .onChange(of: undoManager, initial: true) {
            attachUndoManager(undoManager)
        }
        .onChange(of: model.info?.url) {
            interaction.selectedHandle = nil
            interaction.isEditingText = false
            interaction.viewport = TimelineViewport(duration: model.info?.duration ?? 0)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .empty:
            DropZoneView(isTargeted: isDropTargeted)
        case .failed(let url, let error):
            DropZoneView(isTargeted: isDropTargeted, failure: DropZoneView.Failure(url: url, error: error))
        case .loading(let url):
            LoadingView(url: url)
                .overlay { DropOverlay(isVisible: isDropTargeted) }
        case .ready:
            PlayerView()
                .overlay { DropOverlay(isVisible: isDropTargeted) }
        }
    }

}

private struct DropOverlay: View {
    private enum Metrics {
        static let cornerRadius: CGFloat = 18
        static let borderWidth: CGFloat = 2
        static let tintOpacity = 0.12
    }

    let isVisible: Bool

    var body: some View {
        if isVisible {
            let shape = RoundedRectangle(cornerRadius: Metrics.cornerRadius, style: .continuous)
            Text("Release to open the file")
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .dropTargetBackground(cornerRadius: Metrics.cornerRadius, tintOpacity: Metrics.tintOpacity)
                .overlay(shape.strokeBorder(Color.accentColor, lineWidth: Metrics.borderWidth))
                .allowsHitTesting(false)
        }
    }
}
