import Foundation

public enum StreamCopyStart {
    /// A copied clip starts exactly where asked only in containers with an edit list (MOV, MP4, M4V, M4A,
    /// 3GP): the frames from the key frame to the cut stay in the file but are hidden. Elsewhere the clip
    /// starts on the key frame.
    public static func isExact(for source: URL) -> Bool {
        ExportContainer.forSource(source).hasEditList
    }
}
