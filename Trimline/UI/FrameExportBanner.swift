import AppKit
import SwiftUI
import TrimlineCore

/// A transient note over the video after Save Frame or Copy Frame; it never blocks the window.
/// Also presents the save panel when the frame's location has to be chosen.
struct FrameExportBanner: View {
    private enum Metrics {
        static let spacing: CGFloat = 10
        static let padding = EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 8)
        static let cornerRadius: CGFloat = 14
        static let iconSize: CGFloat = 22
        static let symbolSize: CGFloat = 11
        static let closeSymbolSize: CGFloat = 10
        static let closeSize: CGFloat = 20
    }

    private enum Timing {
        // Quick work never flashes a progress note.
        static let progressDelay: Duration = .milliseconds(400)
        static let copied: Duration = .seconds(3)
        static let saved: Duration = .seconds(6)
        static let failed: Duration = .seconds(10)
        // VoiceOver users need time to reach the buttons.
        static let voiceOverFactor = 4
        static let reducedMotionFade = Animation.easeInOut(duration: 0.15)
    }

    @Environment(EditorModel.self) private var model
    @Environment(InteractionState.self) private var interaction
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @State private var showsProgress = false
    @State private var isHovered = false

    var body: some View {
        ZStack {
            if let note {
                banner(note)
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? Timing.reducedMotionFade : .snappy, value: note)
        // A banner removed under the pointer never reports the pointer leaving.
        .onChange(of: note == nil) { _, isHidden in
            if isHidden {
                isHovered = false
            }
        }
        .task(id: model.frameExport) { await followState() }
        .task(id: HideRequest(state: model.frameExport, isHovered: isHovered)) { await hideWhenDue() }
    }

    // MARK: Content

    private struct Note: Equatable {
        enum Status: Equatable {
            case working
            case done
            case problem
        }

        let status: Status
        let title: String
        var detail: String?
        var savedURL: URL?
    }

    private struct HideRequest: Equatable {
        let state: FrameExportState
        let isHovered: Bool
    }

    private var note: Note? {
        switch model.frameExport {
        case .idle, .choosingDestination:
            return nil
        case .working(let action):
            guard showsProgress else { return nil }
            let title =
                action == .save ? String(localized: "Saving the frame…") : String(localized: "Copying the frame…")
            return Note(status: .working, title: title)
        case .saved(let url):
            return Note(
                status: .done, title: String(localized: "Frame saved"), detail: url.lastPathComponent, savedURL: url)
        case .copied:
            return Note(status: .done, title: String(localized: "Frame copied"))
        case .failed(let action, let error):
            let title =
                action == .save
                ? String(localized: "Couldn’t save the frame") : String(localized: "Couldn’t copy the frame")
            return Note(status: .problem, title: title, detail: error.reason)
        }
    }

    private func banner(_ note: Note) -> some View {
        HStack(spacing: Metrics.spacing) {
            icon(for: note.status)
            VStack(alignment: .leading, spacing: 1) {
                Text(note.title)
                    .font(.callout.weight(.semibold))
                if let detail = note.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            if let url = note.savedURL {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                    model.dismissFrameResult()
                }
                .controlSize(.small)
                .capsuleButtonStyle()
            }
            if note.status != .working {
                Button {
                    model.dismissFrameResult()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: Metrics.closeSymbolSize, weight: .bold))
                        .frame(width: Metrics.closeSize, height: Metrics.closeSize)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(Text("Close"))
                .accessibilityLabel(Text("Close"))
            }
        }
        .padding(Metrics.padding)
        .toastBackground(cornerRadius: Metrics.cornerRadius)
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func icon(for status: Note.Status) -> some View {
        switch status {
        case .working:
            ProgressView()
                .controlSize(.small)
                .frame(width: Metrics.iconSize, height: Metrics.iconSize)
        case .done, .problem:
            Image(systemName: status == .done ? "checkmark" : "exclamationmark")
                .font(.system(size: Metrics.symbolSize, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: Metrics.iconSize, height: Metrics.iconSize)
                .background(status == .done ? TrimColors.success : TrimColors.warning, in: Circle())
                .accessibilityHidden(true)
        }
    }

    // MARK: Behaviour

    private func followState() async {
        switch model.frameExport {
        case .working:
            showsProgress = false
            try? await Task.sleep(for: Timing.progressDelay)
            guard !Task.isCancelled else { return }
            showsProgress = true
        case .choosingDestination(let proposal):
            await chooseDestination(for: proposal)
        case .saved, .copied, .failed:
            showsProgress = false
            announce()
        case .idle:
            showsProgress = false
        }
    }

    private func chooseDestination(for proposal: FrameSaveProposal) async {
        let chosen = await FilePanels.chooseFrameDestination(for: proposal, attachedTo: interaction.editorWindow)
        if let chosen {
            model.confirmFrameSave(to: chosen)
        } else {
            model.cancelFrameSave()
        }
    }

    private func hideWhenDue() async {
        guard !isHovered, let delay = hideDelay else { return }
        try? await Task.sleep(for: voiceOverEnabled ? delay * Timing.voiceOverFactor : delay)
        guard !Task.isCancelled else { return }
        model.dismissFrameResult()
    }

    private var hideDelay: Duration? {
        switch model.frameExport {
        case .copied: Timing.copied
        case .saved: Timing.saved
        case .failed: Timing.failed
        case .idle, .working, .choosingDestination: nil
        }
    }

    private func announce() {
        guard let note else { return }
        let text = [note.title, note.detail].compactMap { $0 }.joined(separator: "\n")
        AccessibilityNotification.Announcement(text).post()
    }
}

extension FrameExportError {
    var reason: String {
        switch self {
        case .frameUnavailable:
            String(localized: "The frame at this position couldn’t be decoded.")
        case .destinationExists:
            String(localized: "A file with this name already exists. Choose another name.")
        case .destinationNotWritable:
            String(localized: "Trimline can’t write to this folder. Choose another location.")
        case .insufficientDiskSpace:
            String(localized: "Not enough disk space to save the frame.")
        case .writeFailed:
            String(localized: "Something went wrong while saving the frame.")
        case .pasteboardUnavailable:
            String(localized: "The frame couldn’t be put on the clipboard.")
        }
    }
}

private enum ToastMetrics {
    static let edgeOpacity = 0.1
    static let edgeWidth: CGFloat = 0.5
    static let shadowOpacity = 0.15
    static let shadowRadius: CGFloat = 8
    static let shadowOffset: CGFloat = 3
}

extension View {
    /// Glass over the video on macOS 26, a material tile on earlier systems.
    @ViewBuilder
    fileprivate func toastBackground(cornerRadius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(macOS 26, *) {
            glassEffect(.regular, in: shape)
        } else {
            background(.regularMaterial, in: shape)
                .overlay(
                    shape.strokeBorder(.primary.opacity(ToastMetrics.edgeOpacity), lineWidth: ToastMetrics.edgeWidth)
                )
                .shadow(
                    color: .black.opacity(ToastMetrics.shadowOpacity), radius: ToastMetrics.shadowRadius,
                    y: ToastMetrics.shadowOffset)
        }
    }
}
