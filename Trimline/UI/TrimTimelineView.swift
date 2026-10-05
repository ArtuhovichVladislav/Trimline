import AppKit
import SwiftUI
import TrimlineCore

struct TrimTimelineView: View {
    enum Metrics {
        static let videoTrackHeight: CGFloat = 56
        static let audioTrackHeight: CGFloat = 72
        static let handleWidth: CGFloat = 14
        static let trackCornerRadius: CGFloat = 11
        static let trackFill = Color.primary.opacity(0.06)
        // The playhead knob rises above the track, its line ends below it.
        static let topOverhang: CGFloat = 10
        static let bottomOverhang: CGFloat = 7
        // Room for the frame's shadow when nothing lies beyond the edges.
        static let shadowOverhang: CGFloat = 8
        static let dimOpacity = 0.72
        static let increasedContrastDimOpacity = 0.86
        static let thumbnailDebounce: Duration = .milliseconds(150)
        static let fallbackAspectRatio: CGFloat = 16 / 9
    }

    private struct ThumbnailRequest: Equatable {
        let count: Int
        let pixelHeight: Int
        let range: ClosedRange<TimeInterval>
    }

    let info: MediaInfo
    let timeFormat: TimeFormat

    @Environment(EditorModel.self) private var model
    @Environment(InteractionState.self) private var interaction
    @Environment(\.displayScale) private var displayScale
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var drag = TimelineDragController()

    private var trackHeight: CGFloat {
        info.kind == .video ? Metrics.videoTrackHeight : Metrics.audioTrackHeight
    }

    private var thumbnailWidth: CGFloat {
        let aspectRatio = info.displaySize.map { $0.height > 0 ? $0.width / $0.height : 0 } ?? 0
        return trackHeight * (aspectRatio > 0 ? aspectRatio : Metrics.fallbackAspectRatio)
    }

    // The previous file's zoom may still be set for the first frame of a new one.
    private var viewport: TimelineViewport {
        interaction.viewport.duration == info.duration
            ? interaction.viewport : TimelineViewport(duration: info.duration)
    }

    var body: some View {
        GeometryReader { proxy in
            let geometry = TimelineGeometry(
                width: proxy.size.width, handleWidth: Metrics.handleWidth, viewport: viewport)
            let dragContext = dragContext(width: proxy.size.width)
            ZStack(alignment: .topLeading) {
                track(geometry)
                    .offset(x: Metrics.handleWidth, y: Metrics.topOverhang)
                TrimFrame(
                    geometry: geometry,
                    selection: model.selection,
                    trackHeight: trackHeight,
                    selectedHandle: interaction.selectedHandle,
                    timeFormat: timeFormat
                )
                .offset(y: Metrics.topOverhang)
                Playhead(height: trackHeight + Metrics.topOverhang + Metrics.bottomOverhang)
                    .offset(x: geometry.drawingX(for: model.currentTime))
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            .clipShape(HorizontalClip(overhang: viewport.isZoomed ? 0 : Metrics.shadowOverhang))
            .contentShape(Rectangle())
            .background { TimelineInputView(handlers: inputHandlers(width: proxy.size.width)) }
            .gesture(dragGesture(dragContext))
            .onContinuousHover { drag.hover($0, dragContext) }
            .task(id: thumbnailRequest(geometry)) {
                await requestThumbnails(thumbnailRequest(geometry))
            }
        }
        .frame(height: trackHeight + Metrics.topOverhang + Metrics.bottomOverhang)
        .onChange(of: model.currentTime) { oldTime, newTime in
            guard !drag.isDragging else { return }
            interaction.viewport.follow(from: oldTime, to: newTime)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Timeline"))
        .accessibilityZoomAction { action in
            if action.direction == .zoomIn {
                interaction.viewport.zoomIn(around: model.currentTime)
            } else {
                interaction.viewport.zoomOut(around: model.currentTime)
            }
        }
    }

    // MARK: Track

    private func track(_ geometry: TimelineGeometry) -> some View {
        let startOffset = geometry.visibleTrackX(for: model.selection.start)
        let endOffset = geometry.visibleTrackX(for: model.selection.end)
        let dim = Color(nsColor: .windowBackgroundColor)
            .opacity(contrast == .increased ? Metrics.increasedContrastDimOpacity : Metrics.dimOpacity)
        return ZStack(alignment: .topLeading) {
            Metrics.trackFill
            trackContent(geometry.viewport)
            dim.frame(width: startOffset)
            dim.frame(width: geometry.trackWidth - endOffset)
                .offset(x: endOffset)
        }
        .frame(width: geometry.trackWidth, height: trackHeight, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: Metrics.trackCornerRadius, style: .continuous))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func trackContent(_ viewport: TimelineViewport) -> some View {
        switch info.kind {
        case .video:
            ThumbnailStrip(
                current: model.thumbnails,
                previous: model.previousThumbnails,
                viewport: viewport,
                tileWidth: thumbnailWidth
            )
        case .audio:
            WaveformView(peaks: model.waveform, viewport: viewport)
        }
    }

    private func thumbnailRequest(_ geometry: TimelineGeometry) -> ThumbnailRequest? {
        guard info.kind == .video, geometry.trackWidth > 0 else { return nil }
        return ThumbnailRequest(
            count: Int((geometry.trackWidth / thumbnailWidth).rounded(.up)),
            pixelHeight: Int((trackHeight * displayScale).rounded()),
            range: geometry.viewport.range
        )
    }

    // Waits out live resizing, zooming and scrolling, then asks once for the visible part.
    private func requestThumbnails(_ request: ThumbnailRequest?) async {
        guard let request else { return }
        try? await Task.sleep(for: Metrics.thumbnailDebounce)
        guard !Task.isCancelled else { return }
        model.requestThumbnails(count: request.count, height: request.pixelHeight, in: request.range)
    }

    // MARK: Input

    private func dragContext(width: CGFloat) -> TimelineDragController.Context {
        TimelineDragController.Context(
            model: model,
            interaction: interaction,
            width: width,
            handleWidth: Metrics.handleWidth,
            knobHeight: Metrics.topOverhang
        )
    }

    private func dragGesture(_ context: TimelineDragController.Context) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                drag.change(from: value.startLocation, to: value.location, context)
            }
            .onEnded { value in
                drag.end(at: value.location, context)
            }
    }

    // Reads the live viewport: several wheel events can arrive between two renders.
    private func inputHandlers(width: CGFloat) -> TimelineInputView.Handlers {
        let model = model
        let interaction = interaction
        let geometry = {
            TimelineGeometry(width: width, handleWidth: Metrics.handleWidth, viewport: interaction.viewport)
        }
        return TimelineInputView.Handlers(
            scroll: { distance in
                guard interaction.viewport.isZoomed else { return false }
                interaction.viewport.scroll(by: TimeInterval(distance) * geometry().secondsPerPoint)
                return true
            },
            magnify: { factor, x in
                interaction.viewport.zoom(by: factor, around: geometry().visibleTime(at: x))
            },
            zoomIn: {
                interaction.viewport.zoomIn(around: model.currentTime)
            }
        )
    }
}

/// Clips only left and right, leaving room above and below for the playhead and shadows.
private struct HorizontalClip: Shape {
    let overhang: CGFloat

    func path(in rect: CGRect) -> Path {
        Path(rect.insetBy(dx: -overhang, dy: -rect.height))
    }
}
