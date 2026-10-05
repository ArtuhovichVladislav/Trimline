import AppKit
import SwiftUI

struct LicenseSheet: View {
    private enum Metrics {
        // Fits the 80-column license files without rewrapping their lines.
        static let width: CGFloat = 640
        static let height: CGFloat = 520
        static let spacing: CGFloat = 12
        static let padding: CGFloat = 20
    }

    let document: LicenseDocument
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing) {
            Text(verbatim: document.title)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            if let text = document.text {
                LicenseTextView(text: text)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text("The license text couldn’t be loaded.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Metrics.padding)
        .frame(width: Metrics.width, height: Metrics.height)
    }
}

// NSTextView handles tens of kilobytes of text, keyboard scrolling and selection better than a SwiftUI Text.
private struct LicenseTextView: NSViewRepresentable {
    private enum Metrics {
        static let inset = NSSize(width: 8, height: 8)
    }

    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.borderType = .lineBorder
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = Metrics.inset
        textView.setAccessibilityLabel(String(localized: "License text"))
        show(text, in: textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView, textView.string != text else { return }
        show(text, in: textView)
    }

    private func show(_ text: String, in textView: NSTextView) {
        textView.string = text
        textView.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        textView.textColor = .textColor
    }
}
