import Foundation

/// A pattern for clip names, such as "{name} (clip)", where `{name}` is the original file's name.
public struct FileNameTemplate: Sendable, Equatable {
    public enum Problem: Error, Sendable, Equatable {
        case empty
        case forbiddenCharacters
        case startsWithDot
        case tooLong
    }

    public static let nameToken = "{name}"
    public static let maximumLength = 120
    // ":" is shown as "/" by Finder, so it is as unusable in a file name as "/" itself.
    private static let forbiddenCharacters = CharacterSet(charactersIn: "/:").union(.controlCharacters)

    public let pattern: String

    /// Validates `pattern`; surrounding whitespace is dropped.
    public init(_ pattern: String) throws(Problem) {
        let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw .empty }
        guard trimmed.rangeOfCharacter(from: Self.forbiddenCharacters) == nil else { throw .forbiddenCharacters }
        guard !trimmed.hasPrefix(".") else { throw .startsWithDot }
        guard trimmed.count <= Self.maximumLength else { throw .tooLong }
        self.pattern = trimmed
    }

    /// "{name} (<suffix>)", the built-in default.
    public static func standard(suffix: String) -> FileNameTemplate {
        FileNameTemplate(validPattern: "\(nameToken) (\(suffix))")
    }

    /// The name without extension; from the second copy on a number is added inside a closing
    /// parenthesis ("Trip (clip 2)") or after the name ("Trip short 2").
    public func baseName(for originalName: String, copyNumber: Int = 1) -> String {
        let name = pattern.replacingOccurrences(of: Self.nameToken, with: originalName)
        guard copyNumber > 1 else { return name }
        if pattern.hasSuffix(")") {
            return "\(name.dropLast()) \(copyNumber))"
        }
        return "\(name) \(copyNumber)"
    }

    private init(validPattern: String) {
        self.pattern = validPattern
    }
}
