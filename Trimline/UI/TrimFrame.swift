import SwiftUI
import TrimlineCore

/// The yellow selection frame with its two handles, which are VoiceOver adjustable elements.
struct TrimFrame: View {
    private enum Metrics {
        static let barHeight: CGFloat = 3
        static let cornerRadius: CGFloat = 12
        static let gripWidth: CGFloat = 3
        static let gripHeight: CGFloat = 18
        static let gripCornerRadius: CGFloat = 2
        static let gripOpacity = 0.55
        static let selectedGripOpacity = 0.95
        static let shadowOpacity = 0.18
        static let shadowRadius: CGFloat = 5
        static let shadowOffset: CGFloat = 2
    }

    let geometry: TimelineGeometry
    let selection: Selection
    let trackHeight: CGFloat
    let selectedHandle: EditorModel.TrimHandle?
    let timeFormat: TimeFormat

    @Environment(EditorModel.self) private var model

    var body: some View {
        let handleWidth = geometry.handleWidth
        let startX = geometry.drawingX(for: selection.start)
        let endX = geometry.drawingX(for: selection.end)
        let height = trackHeight + 2 * Metrics.barHeight

        ZStack(alignment: .topLeading) {
            FrameShape(sideWidth: handleWidth, barHeight: Metrics.barHeight, cornerRadius: Metrics.cornerRadius)
                .fill(TrimColors.frame, style: FillStyle(eoFill: true))
                .shadow(
                    color: .black.opacity(Metrics.shadowOpacity), radius: Metrics.shadowRadius, y: Metrics.shadowOffset
                )
                .frame(width: endX - startX + 2 * handleWidth, height: height)
                .offset(x: startX - handleWidth)
                .allowsHitTesting(false)
            handle(.start)
                .frame(width: handleWidth, height: height)
                .offset(x: startX - handleWidth)
            handle(.end)
                .frame(width: handleWidth, height: height)
                .offset(x: endX)
        }
        .offset(y: -Metrics.barHeight)
    }

    private func handle(_ handle: EditorModel.TrimHandle) -> some View {
        RoundedRectangle(cornerRadius: Metrics.gripCornerRadius)
            .fill(TrimColors.grip.opacity(selectedHandle == handle ? Metrics.selectedGripOpacity : Metrics.gripOpacity))
            .frame(width: Metrics.gripWidth, height: Metrics.gripHeight)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .accessibilityElement()
            .accessibilityLabel(handle == .start ? Text("Clip start") : Text("Clip end"))
            .accessibilityValue(Text(verbatim: timeFormat.string(from: model.handleTime(handle))))
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: model.nudge(handle, frames: 1)
                case .decrement: model.nudge(handle, frames: -1)
                @unknown default: break
                }
            }
    }
}

/// A rounded rectangle with a square opening, filled even-odd so only the border is painted.
private struct FrameShape: Shape {
    let sideWidth: CGFloat
    let barHeight: CGFloat
    let cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path(roundedRect: rect, cornerRadius: cornerRadius, style: .continuous)
        path.addRect(rect.insetBy(dx: sideWidth, dy: barHeight))
        return path
    }
}

struct Playhead: View {
    private enum Metrics {
        static let lineWidth: CGFloat = 2
        static let knobSize: CGFloat = 10
        static let outlineOpacity = 0.45
        static let outlineWidth: CGFloat = 0.5
        static let shadowOpacity = 0.35
        static let shadowRadius: CGFloat = 2
        static let shadowOffset: CGFloat = 1
    }

    let height: CGFloat

    var body: some View {
        ZStack(alignment: .top) {
            Capsule()
                .fill(.white)
                .frame(width: Metrics.lineWidth)
                .overlay(
                    Capsule().strokeBorder(.black.opacity(Metrics.outlineOpacity), lineWidth: Metrics.outlineWidth))
            Circle()
                .fill(.white)
                .overlay(Circle().strokeBorder(.black.opacity(Metrics.outlineOpacity), lineWidth: Metrics.outlineWidth))
                .frame(width: Metrics.knobSize, height: Metrics.knobSize)
        }
        .frame(width: Metrics.knobSize, height: height)
        .shadow(color: .black.opacity(Metrics.shadowOpacity), radius: Metrics.shadowRadius, y: Metrics.shadowOffset)
        .offset(x: -Metrics.knobSize / 2)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
