import Foundation
import Testing

@testable import TrimlineCore

@Suite struct ExportContainerTests {
    @Test(arguments: [
        ("MOV", "mov"), ("mp4", "mp4"), ("m4a", "ipod"), ("mkv", "matroska"), ("webm", "webm"), ("avi", "avi"),
        ("wmv", "asf"), ("flv", "flv"), ("mts", "mpegts"), ("ogg", "ogg"), ("mp3", "mp3"), ("aac", "adts"),
        ("wav", "wav"), ("flac", "flac"), ("wv", "wv"), ("amr", "amr"), ("caf", "caf"), ("aiff", "aiff"),
        ("3gp", "3gp"), ("mpg", "mpeg"), ("vob", "vob"),
    ])
    func keepsWritableContainer(_ fileExtension: String, muxer: String) {
        let container = ExportContainer.forSource(URL(fileURLWithPath: "/tmp/file.\(fileExtension)"))
        #expect(container.fileExtension == fileExtension)
        #expect(container.muxer == muxer)
        #expect(!container.changesContainer)
    }

    @Test(arguments: [("rm", "mkv"), ("rmvb", "mkv"), ("ape", "mka"), ("xyz", "mkv")])
    func fallsBackToMatroska(_ fileExtension: String, expected: String) {
        let container = ExportContainer.forSource(URL(fileURLWithPath: "/tmp/file.\(fileExtension)"))
        #expect(container.fileExtension == expected)
        #expect(container.muxer == "matroska")
        #expect(container.changesContainer)
    }

    @Test func editListMeansExactStart() {
        #expect(StreamCopyStart.isExact(for: URL(fileURLWithPath: "/tmp/a.m4v")))
        #expect(StreamCopyStart.isExact(for: URL(fileURLWithPath: "/tmp/a.3gp")))
        #expect(!StreamCopyStart.isExact(for: URL(fileURLWithPath: "/tmp/a.mkv")))
        #expect(!StreamCopyStart.isExact(for: URL(fileURLWithPath: "/tmp/a.ts")))
    }

    @Test func m2tsFilesKeepTheirPacketSize() {
        #expect(ExportContainer.forSource(URL(fileURLWithPath: "/tmp/a.MTS")).muxerOptions["mpegts_m2ts_mode"] == "1")
        #expect(ExportContainer.forSource(URL(fileURLWithPath: "/tmp/a.ts")).muxerOptions.isEmpty)
    }
}
