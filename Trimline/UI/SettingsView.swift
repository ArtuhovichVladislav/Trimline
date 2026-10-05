import SwiftUI
import TrimlineCore

struct SettingsView: View {
    private enum Metrics {
        static let width: CGFloat = 460
        static let captionSpacing: CGFloat = 4
    }

    @AppStorage(AppSettings.Key.saveMode) private var saveMode = AppSettings.defaultSaveMode
    @AppStorage(AppSettings.Key.saveLocation) private var saveLocation = AppSettings.defaultSaveLocation
    @AppStorage(AppSettings.Key.nameTemplate) private var namePattern = AppSettings.standardTemplate.pattern

    var body: some View {
        Form {
            VStack(alignment: .leading, spacing: Metrics.captionSpacing) {
                Toggle("Cut video to the exact frame", isOn: cutsToFrame)
                    .toggleStyle(.checkbox)
                Text(
                    "MP4, MOV, M4V and 3GP are always cut to the exact frame without re-encoding. In MKV, AVI, TS and other formats, a clip otherwise starts at the previous key frame; with this on, the frames near the cuts are re-encoded instead (the whole video for codecs other than H.264 and HEVC)."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            Picker("Save clips", selection: $saveLocation) {
                Text("Next to the original").tag(SaveLocation.nextToOriginal)
                Text("Always ask where to save").tag(SaveLocation.alwaysAsk)
            }
            .pickerStyle(.radioGroup)
            Section {
                TextField("Clip name", text: $namePattern, prompt: Text(AppSettings.standardTemplate.pattern))
                NameTemplateCaption(pattern: namePattern)
                if namePattern != AppSettings.standardTemplate.pattern {
                    // Removing the key keeps the default following the app language.
                    Button("Restore Default Name") {
                        UserDefaults.standard.removeObject(forKey: AppSettings.Key.nameTemplate)
                    }
                }
            }
            UpdateSettingsSection()
        }
        .formStyle(.grouped)
        .frame(width: Metrics.width)
        .fixedSize(horizontal: false, vertical: true)
    }

    // Stored as the mode, so a "precise" default saved by earlier versions shows as checked.
    private var cutsToFrame: Binding<Bool> {
        Binding(get: { saveMode == .precise }, set: { saveMode = $0 ? .precise : .fast })
    }
}

private struct NameTemplateCaption: View {
    let pattern: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            switch AppSettings.exampleName(for: pattern) {
            case .success(let example):
                Text("Example: \(example)")
                    .foregroundStyle(.secondary)
            case .failure(let problem):
                Text(problem.reason)
                    .foregroundStyle(TrimColors.warning)
                Text("Until it’s fixed, clips get the standard name.")
                    .foregroundStyle(.secondary)
            }
            Text("\(FileNameTemplate.nameToken) is replaced with the original file’s name.")
                .foregroundStyle(.secondary)
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }
}

extension FileNameTemplate.Problem {
    fileprivate var reason: String {
        switch self {
        case .empty: String(localized: "Enter a name.")
        case .forbiddenCharacters: String(localized: "A name can’t contain “/”, “:” or line breaks.")
        case .startsWithDot: String(localized: "A name can’t start with a dot.")
        case .tooLong: String(localized: "The name is longer than \(FileNameTemplate.maximumLength) characters.")
        }
    }
}
