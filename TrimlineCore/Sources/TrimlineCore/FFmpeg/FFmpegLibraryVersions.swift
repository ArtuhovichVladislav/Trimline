import Darwin
import libavutil

/// Versions of the bundled FFmpeg and dav1d libraries, read from the loaded binaries, for the About window.
public enum FFmpegLibraryVersions {
    private static let releaseTagPrefix = "n"
    private static let dav1dVersionSymbol = "dav1d_version"
    // RTLD_DEFAULT from <dlfcn.h>, a pointer-cast macro that Swift doesn't import.
    private static let searchAllImages = -2

    /// FFmpeg release, such as "7.1".
    public static var ffmpeg: String {
        let version = String(cString: av_version_info())
        guard version.hasPrefix(releaseTagPrefix) else { return version }
        return String(version.dropFirst(releaseTagPrefix.count))
    }

    /// dav1d release, such as "1.5.1", or `nil` when the library isn't loaded.
    public static var dav1d: String? {
        // libdav1d ships without a Swift module, so its version function is looked up by name.
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: searchAllImages), dav1dVersionSymbol) else {
            return nil
        }
        typealias VersionFunction = @convention(c) () -> UnsafePointer<CChar>?
        let version = unsafeBitCast(symbol, to: VersionFunction.self)
        return version().map { String(cString: $0) }
    }
}
