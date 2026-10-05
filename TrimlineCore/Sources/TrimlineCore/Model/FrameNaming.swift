import Foundation

/// Names a saved frame after its source and time: "Vacation (frame 01-23.45).png",
/// then "Vacation (frame 01-23.45 2).png". Without a word it is "Vacation (01-23.45).png".
public struct FrameNaming: Sendable {
    public static let fileExtension = "png"
    // Finder shows ":" as "/", so neither may appear in the time.
    private static let forbiddenCharacters = ["/", ":"]
    private static let replacement = "-"

    public let word: String
    private let locale: Locale

    public init(word: String = "", locale: Locale = .autoupdatingCurrent) {
        self.word = word.trimmingCharacters(in: .whitespacesAndNewlines)
        self.locale = locale
    }

    public func frameURL(
        for source: URL,
        at time: TimeInterval,
        fileDuration: TimeInterval,
        in directory: URL? = nil,
        exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> URL {
        let stamp = Self.forbiddenCharacters.reduce(
            TimeFormat(fileDuration: fileDuration, locale: locale).string(from: time)
        ) { $0.replacingOccurrences(of: $1, with: Self.replacement) }
        let template = FileNameTemplate.standard(suffix: word.isEmpty ? stamp : "\(word) \(stamp)")
        return FileNaming(template: template).clipURL(
            for: source, in: directory, fileExtension: Self.fileExtension, exists: exists)
    }
}
