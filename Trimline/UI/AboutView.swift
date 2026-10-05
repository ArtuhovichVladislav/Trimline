import AppKit
import SwiftUI

struct AboutView: View {
    private enum Metrics {
        static let width: CGFloat = 460
        static let iconSize: CGFloat = 96
        static let headerSpacing: CGFloat = 6
        static let sectionSpacing: CGFloat = 12
        static let topPadding: CGFloat = 28
        static let padding: CGFloat = 20
    }

    let app: AppInfo
    let acknowledgements: [Acknowledgement]
    @State private var presentedLicense: LicenseDocument?

    var body: some View {
        VStack(spacing: Metrics.padding) {
            header
            acknowledgementsSection
        }
        .padding(.horizontal, Metrics.padding)
        .padding(.top, Metrics.topPadding)
        .padding(.bottom, Metrics.padding)
        .frame(width: Metrics.width)
        .fixedSize(horizontal: false, vertical: true)
        .sheet(item: $presentedLicense) { LicenseSheet(document: $0) }
    }

    private var header: some View {
        VStack(spacing: Metrics.headerSpacing) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: Metrics.iconSize, height: Metrics.iconSize)
                .accessibilityHidden(true)
            Text(verbatim: app.name)
                .font(.title.bold())
                .accessibilityAddTraits(.isHeader)
            Text("Version \(app.version) (\(app.build))")
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Text("Trim audio and video in seconds.")
                .padding(.top, Metrics.headerSpacing)
            if let copyright = app.copyright {
                Text(verbatim: copyright)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var acknowledgementsSection: some View {
        VStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Acknowledgments")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Text("Trimline is built with these open-source projects.")
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            ForEach(acknowledgements) { acknowledgement in
                AcknowledgementRow(acknowledgement: acknowledgement) {
                    presentedLicense = Acknowledgements.document(for: acknowledgement)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct AcknowledgementRow: View {
    private enum Metrics {
        static let spacing: CGFloat = 6
        static let actionSpacing: CGFloat = 14
    }

    let acknowledgement: Acknowledgement
    let showLicense: () -> Void

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: Metrics.spacing) {
                title
                Text(acknowledgement.summary)
                    .foregroundStyle(.secondary)
                if let notice = acknowledgement.notice {
                    Text(notice)
                        .font(.callout)
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Metrics.actionSpacing) { actions }
                    VStack(alignment: .leading, spacing: Metrics.spacing) { actions }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Metrics.spacing / 2)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: acknowledgement.name))
    }

    private var title: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(verbatim: acknowledgement.name)
                .font(.body.weight(.semibold))
            if let version = acknowledgement.version {
                Text("Version \(version)")
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer(minLength: Metrics.spacing)
            licenseName
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var licenseName: some View {
        switch acknowledgement.license {
        case .localized(let name): Text(name)
        case .verbatim(let name): Text(verbatim: name)
        }
    }

    @ViewBuilder
    private var actions: some View {
        Button("View License", action: showLicense)
            .buttonStyle(.link)
        ForEach(acknowledgement.references) { reference in
            Link(destination: reference.url) {
                Text(reference.title)
            }
            .help(reference.url.absoluteString)
        }
    }
}
