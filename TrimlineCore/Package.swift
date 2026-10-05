// swift-tools-version: 6.2
import PackageDescription

let strictSettings: [SwiftSetting] = [
    .treatAllWarnings(as: .error)
]

// Built by scripts/build-ffmpeg.sh into the repository's Frameworks folder.
let ffmpegLibraries = ["libavutil", "libswresample", "libswscale", "libavcodec", "libavformat", "libdav1d"]

let package = Package(
    name: "TrimlineCore",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TrimlineCore", targets: ["TrimlineCore"])
    ],
    targets: [
        .target(
            name: "TrimlineCore",
            dependencies: ffmpegLibraries.map { .target(name: $0) },
            swiftSettings: strictSettings
        ),
        .testTarget(
            name: "TrimlineCoreTests",
            dependencies: ["TrimlineCore"],
            swiftSettings: strictSettings
        ),
    ] + ffmpegLibraries.map { .binaryTarget(name: $0, path: "Frameworks/\($0).xcframework") },
    swiftLanguageModes: [.v6]
)
