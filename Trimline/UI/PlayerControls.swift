import SwiftUI
import TrimlineCore

/// Transport capsule and current time on the left, Save Frame, Reset and Save Clip on the right.
/// Wraps onto two rows when long translations don't fit side by side.
struct PlayerControls: View {
    private enum Metrics {
        static let rowSpacing: CGFloat = 12
        static let timeSpacing: CGFloat = 10
        static let buttonSpacing: CGFloat = 8
    }

    let timeFormat: TimeFormat

    @Environment(EditorModel.self) private var model

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Metrics.rowSpacing) {
                playback
                Spacer(minLength: Metrics.rowSpacing)
                actions
            }
            VStack(alignment: .leading, spacing: Metrics.rowSpacing) {
                playback
                actions
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .glassGroup()
    }

    private var playback: some View {
        HStack(spacing: Metrics.timeSpacing) {
            TransportControls()
            Text(verbatim: timeFormat.string(from: model.currentTime))
                .font(.body)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .accessibilityLabel(Text("Current time"))
                .accessibilityValue(Text(verbatim: timeFormat.string(from: model.currentTime)))
        }
        .fixedSize()
    }

    private var actions: some View {
        HStack(spacing: Metrics.buttonSpacing) {
            if model.info?.kind == .video {
                saveFrameButton
            }
            Button("Reset") { model.resetSelection() }
                .capsuleButtonStyle()
            Button("Save Clip…") { model.prepareSave() }
                .capsuleButtonStyle(prominent: true)
        }
        .controlSize(.large)
        .fixedSize()
    }

    private var saveFrameButton: some View {
        let title: LocalizedStringKey = model.alwaysAsksForDestination ? "Save Frame…" : "Save Frame"
        return Button {
            model.saveFrame()
        } label: {
            Image(systemName: "camera")
                .accessibilityLabel(Text(title))
        }
        .help(Text(title))
        .capsuleButtonStyle()
        .disabled(!model.canExportFrame)
        .contextMenu {
            Button("Copy Frame") { model.copyFrame(to: FramePasteboard.write) }
        }
    }
}

struct TransportControls: View {
    private enum Metrics {
        static let spacing: CGFloat = 2
        static let padding: CGFloat = 4
    }

    @Environment(EditorModel.self) private var model

    var body: some View {
        HStack(spacing: Metrics.spacing) {
            TransportButton(symbol: "gobackward.5", label: "Back 5 seconds") {
                model.skip(by: -EditorModel.longSkip)
            }
            TransportButton(
                symbol: model.isPlaying ? "pause.fill" : "play.fill",
                label: model.isPlaying ? "Pause" : "Play",
                isProminent: true
            ) {
                model.togglePlayback()
            }
            TransportButton(symbol: "goforward.5", label: "Forward 5 seconds") {
                model.skip(by: EditorModel.longSkip)
            }
            TransportButton(symbol: "repeat", label: "Loop clip", isOn: model.isLooping) {
                model.toggleLooping()
            }
        }
        .padding(Metrics.padding)
        .capsuleBackground()
    }
}

private struct TransportButton: View {
    private enum Metrics {
        static let size: CGFloat = 40
        static let prominentSize: CGFloat = 44
        static let symbolSize: CGFloat = 16
        static let prominentSymbolSize: CGFloat = 19
    }

    let symbol: String
    let label: LocalizedStringKey
    var isProminent = false
    var isOn = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .symbolReplaceTransition()
                .font(.system(size: isProminent ? Metrics.prominentSymbolSize : Metrics.symbolSize, weight: .semibold))
                .frame(
                    width: isProminent ? Metrics.prominentSize : Metrics.size,
                    height: isProminent ? Metrics.prominentSize : Metrics.size
                )
        }
        .buttonStyle(TransportButtonStyle(isProminent: isProminent, isOn: isOn))
        .help(Text(label))
        .accessibilityLabel(Text(label))
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

private struct TransportButtonStyle: ButtonStyle {
    let isProminent: Bool
    let isOn: Bool

    func makeBody(configuration: Configuration) -> some View {
        TransportButtonBody(configuration: configuration, isProminent: isProminent, isOn: isOn)
    }
}

private struct TransportButtonBody: View {
    private enum Metrics {
        static let fillOpacity = 0.14
        static let hoverFillOpacity = 0.22
        static let onFillOpacity = 0.14
        static let pressedScale: CGFloat = 0.94
    }

    let configuration: ButtonStyleConfiguration
    let isProminent: Bool
    let isOn: Bool

    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        configuration.label
            .foregroundStyle(isOn ? Color.accentColor : Color.primary)
            .background(Circle().fill(fill))
            .contentShape(Circle())
            .scaleEffect(configuration.isPressed && !reduceMotion ? Metrics.pressedScale : 1)
            .onHover { isHovered = $0 }
    }

    private var fill: Color {
        if isOn {
            return Color.accentColor.opacity(Metrics.onFillOpacity)
        }
        if isHovered || configuration.isPressed {
            return Color.primary.opacity(isProminent ? Metrics.hoverFillOpacity : Metrics.fillOpacity)
        }
        return isProminent ? Color.primary.opacity(Metrics.fillOpacity) : .clear
    }
}
