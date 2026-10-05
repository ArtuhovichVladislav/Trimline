import Foundation
import ImageIO
import Testing

@testable import TrimlineCore

@Suite struct FrameNamingTests {
    private let source = URL(fileURLWithPath: "/Movies/Vacation.mov")
    private let english = FrameNaming(word: "frame", locale: Locale(identifier: "en_US"))

    @Test func namesFrameAfterSourceAndTime() {
        let url = english.frameURL(for: source, at: 83.45, fileDuration: 600, exists: { _ in false })
        #expect(url.path == "/Movies/Vacation (frame 01-23.45).png")
    }

    @Test func usesLocalizedWordAndDecimalSeparator() {
        let naming = FrameNaming(word: "кадр", locale: Locale(identifier: "ru_RU"))
        let url = naming.frameURL(
            for: URL(fileURLWithPath: "/Movies/Отпуск.mov"), at: 83.45, fileDuration: 600, exists: { _ in false })
        #expect(url.lastPathComponent == "Отпуск (кадр 01-23,45).png")
    }

    @Test func showsHoursForLongFiles() {
        let url = english.frameURL(for: source, at: 3725.5, fileDuration: 7200, exists: { _ in false })
        #expect(url.lastPathComponent == "Vacation (frame 1-02-05.50).png")
    }

    @Test func numbersCopiesInsideParentheses() {
        let taken: Set<String> = ["Vacation (frame 00-01.00).png", "Vacation (frame 00-01.00 2).png"]
        let url = english.frameURL(
            for: source, at: 1, fileDuration: 60, exists: { taken.contains($0.lastPathComponent) })
        #expect(url.lastPathComponent == "Vacation (frame 00-01.00 3).png")
    }

    @Test func leavesOutMissingWord() {
        let url = FrameNaming(locale: Locale(identifier: "en_US"))
            .frameURL(for: source, at: 2, fileDuration: 60, exists: { _ in false })
        #expect(url.lastPathComponent == "Vacation (00-02.00).png")
    }

    @Test func nameHasNoCharactersFinderForbids() {
        let url = english.frameURL(for: source, at: 4000, fileDuration: 8000, exists: { _ in false })
        #expect(!url.lastPathComponent.contains(":"))
        #expect(url.deletingLastPathComponent().path == "/Movies")
    }

    @Test func savesIntoChosenFolder() {
        let folder = URL(fileURLWithPath: "/Pictures", isDirectory: true)
        let url = english.frameURL(for: source, at: 1, fileDuration: 60, in: folder, exists: { _ in false })
        #expect(url.path == "/Pictures/Vacation (frame 00-01.00).png")
    }
}

@Suite struct FrameImageWriterTests {
    @Test func writesPNGAndLeavesNoTemporaryFile() throws {
        let folder = try TestMedia.makeTemporaryFolder()
        let destination = folder.appendingPathComponent("Frame.png")
        let image = try #require(FakeEngine.solidImage(width: 40, height: 20))

        try FrameImageWriter.write(image, to: destination)

        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["Frame.png"])
        let source = try #require(CGImageSourceCreateWithURL(destination as CFURL, nil))
        #expect(CGImageSourceGetType(source) as String? == "public.png")
        let written = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(written.width == 40 && written.height == 20)
    }

    @Test func neverReplacesExistingFile() throws {
        let folder = try TestMedia.makeTemporaryFolder()
        let destination = folder.appendingPathComponent("Frame.png")
        try Data("keep".utf8).write(to: destination)
        let image = try #require(FakeEngine.solidImage(width: 4, height: 4))

        #expect(throws: FrameExportError.destinationExists) { try FrameImageWriter.write(image, to: destination) }
        #expect(try Data(contentsOf: destination) == Data("keep".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["Frame.png"])
    }

    @Test func reportsMissingFolder() throws {
        let folder = try TestMedia.makeTemporaryFolder().appendingPathComponent("gone", isDirectory: true)
        let image = try #require(FakeEngine.solidImage(width: 4, height: 4))
        #expect(throws: FrameExportError.destinationNotWritable) {
            try FrameImageWriter.write(image, to: folder.appendingPathComponent("Frame.png"))
        }
    }
}
