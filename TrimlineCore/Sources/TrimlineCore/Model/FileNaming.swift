import Foundation

public struct FileNaming: Sendable {
    public let template: FileNameTemplate

    public init(template: FileNameTemplate) {
        self.template = template
    }

    public init(suffix: String) {
        self.init(template: .standard(suffix: suffix))
    }

    public func clipURL(
        for source: URL,
        in directory: URL? = nil,
        fileExtension: String? = nil,
        exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> URL {
        let folder = directory ?? source.deletingLastPathComponent()
        let originalName = source.deletingPathExtension().lastPathComponent
        let ext = fileExtension ?? source.pathExtension

        var copyNumber = 1
        while true {
            let name = template.baseName(for: originalName, copyNumber: copyNumber)
            let candidate = folder.appendingPathComponent(ext.isEmpty ? name : "\(name).\(ext)")
            if !exists(candidate) {
                return candidate
            }
            copyNumber += 1
        }
    }
}
