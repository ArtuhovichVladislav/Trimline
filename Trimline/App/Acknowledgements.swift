import Foundation
import TrimlineCore

struct Acknowledgement: Identifiable {
    struct Reference: Identifiable {
        let title: LocalizedStringResource
        let url: URL
        var id: URL { url }
    }

    enum LicenseName {
        case localized(LocalizedStringResource)
        case verbatim(String)
    }

    let name: String
    let version: String?
    let summary: LocalizedStringResource
    let license: LicenseName
    let notice: LocalizedStringResource?
    let references: [Reference]
    let licenseFiles: [String]
    var id: String { name }
}

struct LicenseDocument: Identifiable {
    let title: String
    let text: String?
    var id: String { title }
}

enum Acknowledgements {
    private enum Address {
        static let ffmpegSource = "https://github.com/ArtuhovichVladislav/Trimline/releases"
        static let ffmpegWebsite = "https://ffmpeg.org"
        static let dav1dWebsite = "https://code.videolan.org/videolan/dav1d"
        static let sparkleWebsite = "https://sparkle-project.org"
    }

    private static let licenseFileExtension = "txt"
    private static let documentSeparator = "\n\n"
    private static let sparkleFramework = "Sparkle.framework"
    private static let shortVersionKey = "CFBundleShortVersionString"

    static var all: [Acknowledgement] {
        [ffmpeg, dav1d, sparkle]
    }

    static func document(for acknowledgement: Acknowledgement) -> LicenseDocument {
        let texts = acknowledgement.licenseFiles.compactMap(licenseText(named:))
        let isComplete = texts.count == acknowledgement.licenseFiles.count
        return LicenseDocument(
            title: String(localized: "\(acknowledgement.name) License"),
            text: isComplete ? texts.joined(separator: documentSeparator) : nil
        )
    }

    private static var ffmpeg: Acknowledgement {
        Acknowledgement(
            name: "FFmpeg",
            version: FFmpegLibraryVersions.ffmpeg,
            summary: "Reading and writing audio and video formats",
            license: .localized("LGPL 2.1 or later"),
            notice: """
                FFmpeg is linked dynamically, so you can replace it with your own build. \
                The exact source code, build script and instructions are attached to every Trimline release on GitHub.
                """,
            references: references([
                ("Source Code", Address.ffmpegSource),
                ("Website", Address.ffmpegWebsite),
            ]),
            licenseFiles: ["FFmpeg-LICENSE", "LGPL-2.1"]
        )
    }

    private static var dav1d: Acknowledgement {
        Acknowledgement(
            name: "dav1d",
            version: FFmpegLibraryVersions.dav1d,
            summary: "AV1 video decoding",
            license: .verbatim("BSD 2-Clause"),
            notice: nil,
            references: references([("Website", Address.dav1dWebsite)]),
            licenseFiles: ["dav1d-COPYING"]
        )
    }

    private static var sparkle: Acknowledgement {
        Acknowledgement(
            name: "Sparkle",
            version: sparkleVersion,
            summary: "App updates",
            license: .verbatim("MIT"),
            notice: nil,
            references: references([("Website", Address.sparkleWebsite)]),
            licenseFiles: ["Sparkle-LICENSE"]
        )
    }

    private static var sparkleVersion: String? {
        guard let frameworks = Bundle.main.privateFrameworksURL else { return nil }
        let bundle = Bundle(url: frameworks.appending(path: sparkleFramework))
        return bundle?.object(forInfoDictionaryKey: shortVersionKey) as? String
    }

    private static func references(_ items: [(LocalizedStringResource, String)]) -> [Acknowledgement.Reference] {
        items.compactMap { title, address in
            URL(string: address).map { Acknowledgement.Reference(title: title, url: $0) }
        }
    }

    private static func licenseText(named name: String) -> String? {
        let url = Bundle.main.url(forResource: name, withExtension: licenseFileExtension)
        return url.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    }
}
