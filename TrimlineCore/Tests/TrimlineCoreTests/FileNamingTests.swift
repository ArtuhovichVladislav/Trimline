import Foundation
import Testing

@testable import TrimlineCore

@Suite struct FileNamingTests {
    private let naming = FileNaming(suffix: "clip")
    private let source = URL(fileURLWithPath: "/Users/me/Movies/Holiday.mov")

    @Test func addsSuffixBeforeExtension() {
        let url = naming.clipURL(for: source, exists: { _ in false })
        #expect(url.path == "/Users/me/Movies/Holiday (clip).mov")
    }

    @Test func countsCollisions() {
        let taken: Set<String> = ["Holiday (clip).mov", "Holiday (clip 2).mov"]
        let url = naming.clipURL(for: source, exists: { taken.contains($0.lastPathComponent) })
        #expect(url.lastPathComponent == "Holiday (clip 3).mov")
    }

    @Test func secondClipGetsNumberTwo() {
        let url = naming.clipURL(for: source, exists: { $0.lastPathComponent == "Holiday (clip).mov" })
        #expect(url.lastPathComponent == "Holiday (clip 2).mov")
    }

    @Test func fileWithoutExtension() {
        let url = naming.clipURL(for: URL(fileURLWithPath: "/tmp/Recording"), exists: { _ in false })
        #expect(url.lastPathComponent == "Recording (clip)")
    }

    @Test func keepsInnerDots() {
        let url = naming.clipURL(for: URL(fileURLWithPath: "/tmp/my.trip.2026.mp4"), exists: { _ in false })
        #expect(url.lastPathComponent == "my.trip.2026 (clip).mp4")
    }

    @Test func usesLocalizedSuffix() {
        let url = FileNaming(suffix: "клип").clipURL(
            for: source, exists: { $0.lastPathComponent == "Holiday (клип).mov" })
        #expect(url.lastPathComponent == "Holiday (клип 2).mov")
    }

    @Test func customDirectoryAndExtension() {
        let folder = URL(fileURLWithPath: "/Volumes/Backup/Clips", isDirectory: true)
        let url = naming.clipURL(for: source, in: folder, fileExtension: "mkv", exists: { _ in false })
        #expect(url.path == "/Volumes/Backup/Clips/Holiday (clip).mkv")
    }

    @Test func checksRealDiskByDefault() throws {
        let folder = try TestMedia.makeTemporaryFolder()
        let file = folder.appendingPathComponent("Song.m4a")
        try Data().write(to: folder.appendingPathComponent("Song (clip).m4a"))
        #expect(naming.clipURL(for: file).lastPathComponent == "Song (clip 2).m4a")
    }
    // MARK: Templates

    @Test func templateReplacesNameToken() throws {
        let naming = FileNaming(template: try FileNameTemplate("short {name}"))
        let url = naming.clipURL(for: source, exists: { $0.lastPathComponent == "short Holiday.mov" })
        #expect(url.lastPathComponent == "short Holiday 2.mov")
    }

    @Test func templateWithClosingParenthesisNumbersInside() throws {
        let naming = FileNaming(template: try FileNameTemplate("{name} [cut] (part)"))
        let url = naming.clipURL(for: source, exists: { $0.lastPathComponent == "Holiday [cut] (part).mov" })
        #expect(url.lastPathComponent == "Holiday [cut] (part 2).mov")
    }

    @Test func templateWithoutTokenStillAvoidsCollisions() throws {
        let naming = FileNaming(template: try FileNameTemplate("Clip"))
        let url = naming.clipURL(for: source, exists: { $0.lastPathComponent == "Clip.mov" })
        #expect(url.lastPathComponent == "Clip 2.mov")
    }

    @Test func nameAloneNeverReplacesOriginal() throws {
        let naming = FileNaming(template: try FileNameTemplate(FileNameTemplate.nameToken))
        let url = naming.clipURL(for: source, exists: { $0 == source })
        #expect(url.lastPathComponent == "Holiday 2.mov")
    }

    @Test func numberGoesAfterNameEndingInParenthesis() throws {
        let template = try FileNameTemplate("{name}")
        #expect(template.baseName(for: "Trip (1)", copyNumber: 2) == "Trip (1) 2")
    }

    @Test func standardTemplateMatchesSuffixNaming() {
        #expect(FileNameTemplate.standard(suffix: "клип").pattern == "{name} (клип)")
    }

    @Test func templateIsTrimmed() throws {
        #expect(try FileNameTemplate("  {name} cut \n").pattern == "{name} cut")
    }

    @Test(arguments: [
        ("", FileNameTemplate.Problem.empty),
        ("   ", .empty),
        ("{name}/clip", .forbiddenCharacters),
        ("{name}: clip", .forbiddenCharacters),
        ("{name}\tclip", .forbiddenCharacters),
        (".{name}", .startsWithDot),
        (String(repeating: "a", count: FileNameTemplate.maximumLength + 1), .tooLong),
    ])
    func invalidTemplatesAreRejected(pattern: String, problem: FileNameTemplate.Problem) {
        #expect(throws: problem) { try FileNameTemplate(pattern) }
    }
}
