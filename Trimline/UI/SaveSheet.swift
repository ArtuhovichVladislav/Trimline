import AppKit
import SwiftUI
import TrimlineCore

struct SaveSheet: View {
    enum Metrics {
        static let width: CGFloat = 380
        static let padding: CGFloat = 20
        static let titleSpacing: CGFloat = 14
        static let labelSpacing: CGFloat = 6
        static let sectionSpacing: CGFloat = 14
        static let infoSpacing = EdgeInsets(top: 10, leading: 0, bottom: 18, trailing: 0)
        static let warningSpacing: CGFloat = 6
        static let buttonSpacing: CGFloat = 8
        static let statusSpacing: CGFloat = 12
        static let statusIconSize: CGFloat = 32
        static let statusSymbolSize: CGFloat = 16
        static let resultSpacing: CGFloat = 18
        static let hintSpacing: CGFloat = 4
        static let fileIconSize: CGFloat = 40
        static let badgeSize: CGFloat = 16
        static let badgeSymbolSize: CGFloat = 8
        static let badgeOffset: CGFloat = 3
        static let preparingHeight: CGFloat = 60
    }

    @Environment(EditorModel.self) private var model
    @Environment(\.locale) private var locale

    var body: some View {
        content
            .padding(Metrics.padding)
            .frame(width: Metrics.width)
            .interactiveDismissDisabled()
    }

    @ViewBuilder
    private var content: some View {
        let timeFormat = TimeFormat(fileDuration: model.info?.duration ?? 0, locale: locale)
        switch model.saveState {
        case .confirming(let proposal):
            SaveConfirmation(proposal: proposal, timeFormat: timeFormat)
        case .saving(let progress):
            SaveProgress(progress: progress)
        case .saved(let url, let length):
            SaveSuccess(url: url, length: timeFormat.string(from: length))
        case .failed(let error):
            SaveFailure(error: error)
        case .idle, .preparing:
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, minHeight: Metrics.preparingHeight)
        }
    }
}

private struct SaveConfirmation: View {
    let proposal: SaveProposal
    let timeFormat: TimeFormat

    @Environment(EditorModel.self) private var model
    @State private var fileName: String
    @State private var isChoosingDestination = false

    init(proposal: SaveProposal, timeFormat: TimeFormat) {
        self.proposal = proposal
        self.timeFormat = timeFormat
        _fileName = State(initialValue: proposal.destination.lastPathComponent)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Save Clip")
                .font(.title3.weight(.semibold))
                .padding(.bottom, SaveSheet.Metrics.titleSpacing)
            if !proposal.asksForDestination {
                nameField
            }
            if model.canChooseExportContent {
                SaveContentPicker()
            }
            details
            buttons
        }
        .onChange(of: proposal.destination) { old, new in
            fileName = Self.fileName(fileName, movedFrom: old, to: new)
        }
    }

    // A recomputed proposal may bring another extension or copy number; a name the user typed keeps its stem.
    private static func fileName(_ typed: String, movedFrom old: URL, to new: URL) -> String {
        guard typed != old.lastPathComponent else { return new.lastPathComponent }
        let name = typed as NSString
        guard name.pathExtension.caseInsensitiveCompare(old.pathExtension) == .orderedSame,
            let renamed = (name.deletingPathExtension as NSString).appendingPathExtension(new.pathExtension)
        else { return typed }
        return renamed
    }

    private var nameField: some View {
        VStack(alignment: .leading, spacing: SaveSheet.Metrics.labelSpacing) {
            Text("New file name")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack(spacing: SaveSheet.Metrics.buttonSpacing) {
                TextField(text: $fileName) { Text("New file name") }
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(save)
                Button(action: chooseDestination) {
                    Image(systemName: "folder")
                        .accessibilityLabel(Text("Save to Another Folder…"))
                }
                .help(Text("Save to Another Folder…"))
                .capsuleButtonStyle()
                .disabled(!model.isSaveProposalCurrent || isChoosingDestination)
            }
        }
        .padding(.bottom, SaveSheet.Metrics.sectionSpacing)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: SaveSheet.Metrics.warningSpacing) {
            Text(rangeDescription)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            if proposal.content == .soundOnly {
                Text("The clip will be saved as \(proposal.destination.pathExtension.uppercased()).")
                    .foregroundStyle(.secondary)
            } else if proposal.changesContainer {
                Text(containerWarning)
                    .foregroundStyle(TrimColors.warning)
            }
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
        .padding(SaveSheet.Metrics.infoSpacing)
    }

    private var buttons: some View {
        HStack(spacing: SaveSheet.Metrics.buttonSpacing) {
            Spacer()
            Button("Cancel") { model.cancelSave() }
                .keyboardShortcut(.cancelAction)
                .capsuleButtonStyle()
            Button(saveTitle, action: save)
                .keyboardShortcut(.defaultAction)
                .capsuleButtonStyle(prominent: true)
                .disabled(
                    !model.isSaveProposalCurrent
                        || isChoosingDestination || (!proposal.asksForDestination && destination == nil))
        }
        .controlSize(.large)
        .glassGroup()
    }

    private var saveTitle: LocalizedStringKey {
        proposal.asksForDestination ? "Save…" : "Save"
    }

    private var rangeDescription: LocalizedStringKey {
        let start = timeFormat.string(from: proposal.range.lowerBound)
        let end = timeFormat.string(from: proposal.range.upperBound)
        let length = timeFormat.string(from: proposal.length)
        return proposal.asksForDestination
            ? "\(start) – \(end), length \(length). You’ll choose where to save the new file."
            : "\(start) – \(end), length \(length). The new file is saved next to the original."
    }

    private var containerWarning: LocalizedStringKey {
        proposal.destination.pathExtension.lowercased() == "mka"
            ? "This format can’t be written. The clip will be saved as MKA."
            : "This format can’t be written. The clip will be saved as MKV."
    }

    // Keeps the clip's extension when the typed name drops or changes it.
    private var destination: URL? {
        let name = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("/") else { return nil }
        let fileExtension = proposal.destination.pathExtension
        let typedExtension = (name as NSString).pathExtension
        let fullName =
            fileExtension.isEmpty || typedExtension.caseInsensitiveCompare(fileExtension) == .orderedSame
            ? name
            : "\(name).\(fileExtension)"
        return proposal.destination.deletingLastPathComponent().appendingPathComponent(fullName)
    }

    private func save() {
        if proposal.asksForDestination {
            chooseDestination()
        } else if let destination {
            model.confirmSave(to: destination)
        }
    }

    private func chooseDestination() {
        isChoosingDestination = true
        Task {
            let chosen = await FilePanels.chooseDestination(
                for: proposal, named: destination?.lastPathComponent, attachedTo: NSApp.keyWindow)
            isChoosingDestination = false
            if let chosen {
                model.confirmSave(to: chosen)
            }
        }
    }
}

/// Picture and sound or either alone; offered only for a video with sound.
private struct SaveContentPicker: View {
    @Environment(EditorModel.self) private var model

    var body: some View {
        Picker("Clip contents", selection: content) {
            Text("Video and sound").tag(ExportContent.videoAndSound)
            Text("Video only").tag(ExportContent.videoOnly)
            Text("Sound only").tag(ExportContent.soundOnly)
        }
        .pickerStyle(.radioGroup)
        .labelsHidden()
        .fixedSize(horizontal: false, vertical: true)
        .padding(.bottom, SaveSheet.Metrics.sectionSpacing)
    }

    private var content: Binding<ExportContent> {
        Binding(get: { model.effectiveExportContent }, set: { model.exportContent = $0 })
    }
}

private struct SaveProgress: View {
    let progress: Double

    @Environment(EditorModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: SaveSheet.Metrics.statusSpacing) {
            Text("Saving…")
                .font(.title3.weight(.semibold))
            ProgressView(value: progress)
                .progressViewStyle(.linear)
                .accessibilityLabel(Text("Saving progress"))
            HStack {
                Spacer()
                Button("Cancel") { model.cancelSave() }
                    .keyboardShortcut(.cancelAction)
                    .capsuleButtonStyle()
                    .controlSize(.large)
            }
        }
    }
}

private struct SaveSuccess: View {
    let url: URL
    let length: String

    @Environment(EditorModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: SaveSheet.Metrics.resultSpacing) {
            HStack(alignment: .top, spacing: SaveSheet.Metrics.statusSpacing) {
                DraggableFileIcon(url: url)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Clip saved")
                        .font(.body.weight(.semibold))
                    Text("“\(url.lastPathComponent)”, \(length)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Text("Drag the icon into another app to send the clip.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, SaveSheet.Metrics.hintSpacing)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: SaveSheet.Metrics.buttonSpacing) {
                // Icon only: three titled buttons overflow the sheet in Russian and German.
                ShareLink(item: url) {
                    Image(systemName: "square.and.arrow.up")
                        .accessibilityLabel(Text("Share"))
                }
                .help(Text("Share"))
                .capsuleButtonStyle()
                Spacer()
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                    model.dismissSaveResult()
                }
                .capsuleButtonStyle()
                Button("Done") { model.dismissSaveResult() }
                    .keyboardShortcut(.defaultAction)
                    .capsuleButtonStyle(prominent: true)
            }
            .controlSize(.large)
            .glassGroup()
        }
    }
}

/// The saved file's Finder icon with a success badge; dragging it hands the file itself to the drop target.
private struct DraggableFileIcon: View {
    let url: URL

    var body: some View {
        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
            .resizable()
            .frame(width: SaveSheet.Metrics.fileIconSize, height: SaveSheet.Metrics.fileIconSize)
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: "checkmark")
                    .font(.system(size: SaveSheet.Metrics.badgeSymbolSize, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: SaveSheet.Metrics.badgeSize, height: SaveSheet.Metrics.badgeSize)
                    .background(TrimColors.success, in: Circle())
                    .offset(x: SaveSheet.Metrics.badgeOffset, y: SaveSheet.Metrics.badgeOffset)
            }
            .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
            .accessibilityElement()
            .accessibilityLabel(Text(verbatim: url.lastPathComponent))
            .accessibilityHint(Text("Drag the icon into another app to send the clip."))
    }
}

private struct SaveFailure: View {
    let error: ExportError

    @Environment(EditorModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: SaveSheet.Metrics.resultSpacing) {
            SaveStatus(symbol: "exclamationmark", color: TrimColors.warning) {
                Text("Couldn’t save the clip")
                    .font(.body.weight(.semibold))
                Text(error.reason)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let detail = error.detail {
                    Text(verbatim: detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            HStack(spacing: SaveSheet.Metrics.buttonSpacing) {
                Spacer()
                Button("Done") { model.dismissSaveResult() }
                    .keyboardShortcut(.cancelAction)
                    .capsuleButtonStyle()
                Button("Try Again") { model.prepareSave() }
                    .keyboardShortcut(.defaultAction)
                    .capsuleButtonStyle(prominent: true)
            }
            .controlSize(.large)
            .glassGroup()
        }
    }
}

private struct SaveStatus<Message: View>: View {
    let symbol: String
    let color: Color
    @ViewBuilder let message: Message

    var body: some View {
        HStack(alignment: .top, spacing: SaveSheet.Metrics.statusSpacing) {
            Image(systemName: symbol)
                .font(.system(size: SaveSheet.Metrics.statusSymbolSize, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: SaveSheet.Metrics.statusIconSize, height: SaveSheet.Metrics.statusIconSize)
                .background(color, in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                message
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}
