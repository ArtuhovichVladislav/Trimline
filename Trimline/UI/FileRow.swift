import SwiftUI
import TrimlineCore

struct FileRow: View {
    private enum Metrics {
        static let spacing: CGFloat = 10
        static let badgeSize: CGFloat = 34
        static let badgeCornerRadius: CGFloat = 9
        static let badgeSymbolSize: CGFloat = 16
        static let badgeTintOpacity = 0.12
        static let lineSpacing: CGFloat = 1
        static let buttonSpacing: CGFloat = 8
    }

    let symbolName: String
    let name: String
    let details: String

    @Environment(EditorModel.self) private var model
    @Environment(\.fileActions) private var fileActions

    var body: some View {
        HStack(spacing: Metrics.spacing) {
            badge
            VStack(alignment: .leading, spacing: Metrics.lineSpacing) {
                Text(verbatim: name)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(verbatim: details)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: Metrics.buttonSpacing) {
                Button("Another File…") { fileActions.choose() }
                    .capsuleButtonStyle()
                Button {
                    model.closeCurrentFile()
                } label: {
                    Image(systemName: "xmark")
                        .accessibilityLabel(Text("Close File"))
                }
                .help(Text("Close File"))
                .capsuleButtonStyle()
            }
            .controlSize(.large)
            .fixedSize()
            .glassGroup()
        }
    }

    private var badge: some View {
        Image(systemName: symbolName)
            .font(.system(size: Metrics.badgeSymbolSize, weight: .medium))
            .foregroundStyle(Color.accentColor)
            .frame(width: Metrics.badgeSize, height: Metrics.badgeSize)
            .background(
                Color.accentColor.opacity(Metrics.badgeTintOpacity),
                in: RoundedRectangle(cornerRadius: Metrics.badgeCornerRadius, style: .continuous)
            )
            .accessibilityHidden(true)
    }
}
