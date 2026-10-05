import SwiftUI
import TrimlineCore

struct LoadingView: View {
    let url: URL

    @Environment(EditorModel.self) private var model

    var body: some View {
        VStack(spacing: PlayerView.Metrics.fileRowSpacing) {
            FileRow(symbolName: "waveform", name: url.lastPathComponent, details: String(localized: "Opening…"))
            RoundedRectangle(cornerRadius: TrimTimelineView.Metrics.trackCornerRadius, style: .continuous)
                .fill(TrimTimelineView.Metrics.trackFill)
                .frame(height: TrimTimelineView.Metrics.videoTrackHeight)
                .padding(.horizontal, TrimTimelineView.Metrics.handleWidth)
                .overlay {
                    if model.showsLoadingIndicator {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
        }
    }
}
