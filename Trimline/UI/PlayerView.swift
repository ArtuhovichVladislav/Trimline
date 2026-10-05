import SwiftUI
import TrimlineCore

struct PlayerView: View {
    enum Metrics {
        static let fileRowSpacing: CGFloat = 12
        static let stageSpacing: CGFloat = 16
        static let timelineTopSpacing: CGFloat = 4
        static let timesTopSpacing: CGFloat = 10
        static let timesInset: CGFloat = 14
        static let controlsTopSpacing: CGFloat = 16
        static let stageCornerRadius: CGFloat = 16
        static let stageAspectRatio: CGFloat = 16 / 9
        static let stageEdgeOpacity = 0.2
        static let stageEdgeWidth: CGFloat = 0.5
        static let bannerInset: CGFloat = 10
    }

    @Environment(EditorModel.self) private var model
    @Environment(\.locale) private var locale

    var body: some View {
        if let info = model.info {
            let timeFormat = TimeFormat(fileDuration: info.duration, locale: locale)
            VStack(spacing: 0) {
                FileRow(
                    symbolName: info.kind == .video ? "video" : "music.note",
                    name: info.url.lastPathComponent,
                    details: info.summary(using: timeFormat)
                )
                .padding(.bottom, Metrics.fileRowSpacing)
                if info.kind == .video {
                    videoStage
                        .padding(.bottom, Metrics.stageSpacing)
                }
                TrimTimelineView(info: info, timeFormat: timeFormat)
                    .padding(.top, Metrics.timelineTopSpacing)
                TimesRow(timeFormat: timeFormat)
                    .padding(.top, Metrics.timesTopSpacing)
                    .padding(.horizontal, Metrics.timesInset)
                PlayerControls(timeFormat: timeFormat)
                    .padding(.top, Metrics.controlsTopSpacing)
            }
        }
    }

    private var videoStage: some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.stageCornerRadius, style: .continuous)
        return VideoSurfaceView(surface: model.playback?.surface)
            .aspectRatio(Metrics.stageAspectRatio, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .background(.black)
            .clipShape(shape)
            .overlay(shape.strokeBorder(.black.opacity(Metrics.stageEdgeOpacity), lineWidth: Metrics.stageEdgeWidth))
            .accessibilityHidden(true)
            .overlay(alignment: .bottom) {
                FrameExportBanner()
                    .padding(Metrics.bannerInset)
            }
    }
}
