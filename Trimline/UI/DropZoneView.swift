import SwiftUI
import TrimlineCore

struct DropZoneView: View {
    struct Failure {
        let url: URL
        let error: MediaOpenError
    }

    private enum Metrics {
        static let cornerRadius: CGFloat = 18
        static let borderWidth: CGFloat = 1.5
        static let dash: [CGFloat] = [6, 4]
        static let iconSize: CGFloat = 60
        static let iconCornerRadius: CGFloat = 16
        static let symbolSize: CGFloat = 30
        static let padding = EdgeInsets(top: 40, leading: 24, bottom: 30, trailing: 24)
        static let iconSpacing: CGFloat = 16
        static let subtitleSpacing: CGFloat = 4
        static let actionsSpacing: CGFloat = 18
        static let formatsSpacing: CGFloat = 16
        static let buttonSpacing: CGFloat = 8
        static let targetedTintOpacity = 0.1
        static let idleBorderOpacity = 0.4
        static let dimmedActionsOpacity = 0.35
        static let targetedIconLift: CGFloat = -3
        static let targetedIconScale: CGFloat = 1.06
        static let animation = Animation.easeOut(duration: 0.15)
    }

    let isTargeted: Bool
    var failure: Failure?

    @Environment(\.fileActions) private var fileActions
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            icon
                .padding(.bottom, Metrics.iconSpacing)
            title
                .font(.title2.weight(.semibold))
            subtitle
                .font(.body)
                .foregroundStyle(.secondary)
                .padding(.top, Metrics.subtitleSpacing)
            actions
                .padding(.top, Metrics.actionsSpacing)
                .opacity(isTargeted ? Metrics.dimmedActionsOpacity : 1)
            Text("MP4, MOV, MKV, AVI, MP3, FLAC and many more")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.top, Metrics.formatsSpacing)
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .padding(Metrics.padding)
        .frame(maxWidth: .infinity)
        .background { border }
        .animation(reduceMotion ? nil : Metrics.animation, value: isTargeted)
    }

    private var icon: some View {
        Image(systemName: failure == nil ? "waveform" : "exclamationmark.triangle")
            .font(.system(size: Metrics.symbolSize, weight: .medium))
            .foregroundStyle(failure == nil ? Color.accentColor : TrimColors.warning)
            .frame(width: Metrics.iconSize, height: Metrics.iconSize)
            .raisedTileBackground(cornerRadius: Metrics.iconCornerRadius)
            .scaleEffect(isTargeted && !reduceMotion ? Metrics.targetedIconScale : 1)
            .offset(y: isTargeted && !reduceMotion ? Metrics.targetedIconLift : 0)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var title: some View {
        if isTargeted {
            Text("Release to open the file")
        } else if let failure {
            Text("Couldn’t open “\(failure.url.lastPathComponent)”")
        } else {
            Text("Drop audio or video here")
        }
    }

    @ViewBuilder
    private var subtitle: some View {
        if let failure, !isTargeted {
            Text(failure.error.reason)
        } else {
            Text("Almost any audio or video format")
        }
    }

    private var actions: some View {
        HStack(spacing: Metrics.buttonSpacing) {
            if let failure {
                Button("Try Again") { fileActions.open([failure.url]) }
                    .capsuleButtonStyle()
            }
            Button("Choose in Finder…") { fileActions.choose() }
                .capsuleButtonStyle(prominent: true)
        }
        .controlSize(.extraLarge)
        .fixedSize()
        .glassGroup()
    }

    private var border: some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.cornerRadius, style: .continuous)
        return
            shape
            .fill(isTargeted ? Color.accentColor.opacity(Metrics.targetedTintOpacity) : .clear)
            .overlay(
                shape.strokeBorder(
                    isTargeted ? Color.accentColor : Color.secondary.opacity(Metrics.idleBorderOpacity),
                    style: StrokeStyle(lineWidth: Metrics.borderWidth, dash: Metrics.dash)
                )
            )
    }
}
