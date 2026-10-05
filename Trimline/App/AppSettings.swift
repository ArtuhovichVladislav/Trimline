import Foundation
import TrimlineCore

enum SaveLocation: String, CaseIterable {
    case nextToOriginal
    case alwaysAsk
}

/// Keys and defaults of the Settings window; the values reach `EditorModel` through `SettingsSync`.
enum AppSettings {
    enum Key {
        static let saveMode = "defaultSaveMode"
        static let saveLocation = "saveLocation"
        static let nameTemplate = "clipNameTemplate"
    }

    static let defaultSaveMode = ExportMode.fast
    static let defaultSaveLocation = SaveLocation.nextToOriginal

    static var clipSuffix: String {
        String(localized: "clip", comment: "Suffix of a new clip file: “Vacation (clip).mov”")
    }

    static var standardTemplate: FileNameTemplate { .standard(suffix: clipSuffix) }

    static var frameWord: String {
        String(localized: "frame", comment: "Word in a saved frame’s file name: “Vacation (frame 01-23.45).png”")
    }

    static var sampleFileName: String {
        String(localized: "Vacation", comment: "Example source file name in Settings: “Vacation (clip).mov”")
    }

    static let sampleFileExtension = "mov"

    /// An invalid or missing pattern falls back to the standard template.
    static func template(from pattern: String?) -> FileNameTemplate {
        guard let pattern, let template = try? FileNameTemplate(pattern) else { return standardTemplate }
        return template
    }

    static func exampleName(for pattern: String) -> Result<String, FileNameTemplate.Problem> {
        do throws(FileNameTemplate.Problem) {
            let name = try FileNameTemplate(pattern).baseName(for: sampleFileName)
            return .success("\(name).\(sampleFileExtension)")
        } catch {
            return .failure(error)
        }
    }
}

/// Pushes the stored settings into the model at launch and whenever they change.
@MainActor
final class SettingsSync {
    private let model: EditorModel
    private let defaults: UserDefaults
    private var observer: NSObjectProtocol?

    init(model: EditorModel, defaults: UserDefaults = .standard) {
        self.model = model
        self.defaults = defaults
    }

    func start() {
        apply()
        observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: defaults, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.apply() }
        }
    }

    // The notification fires for every key, including window frames, so unchanged values are skipped.
    private func apply() {
        let mode = stored(AppSettings.Key.saveMode, default: AppSettings.defaultSaveMode)
        if model.exportMode != mode {
            model.exportMode = mode
        }
        let asks = stored(AppSettings.Key.saveLocation, default: AppSettings.defaultSaveLocation) == .alwaysAsk
        if model.alwaysAsksForDestination != asks {
            model.alwaysAsksForDestination = asks
        }
        let template = AppSettings.template(from: defaults.string(forKey: AppSettings.Key.nameTemplate))
        if model.naming.template != template {
            model.naming = FileNaming(template: template)
        }
    }

    private func stored<Value: RawRepresentable<String>>(_ key: String, default fallback: Value) -> Value {
        guard let raw = defaults.string(forKey: key), let value = Value(rawValue: raw) else { return fallback }
        return value
    }
}
