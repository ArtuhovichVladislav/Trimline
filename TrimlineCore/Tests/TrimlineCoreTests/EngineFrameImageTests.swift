import CoreGraphics
import Foundation
import Testing

@testable import TrimlineCore

// Every frame of these movies has its own flat red level, so a picture tells which frame it is.
enum FrameFixtures {
    struct Movie: Sendable, CustomTestStringConvertible {
        let fileName: String
        let codec: [String]
        var filters = ""
        var input: [String] = []
        let opensWithAVFoundation: Bool

        var testDescription: String { fileName }

        func make() throws -> URL {
            try ExternalFFmpeg.make(
                fileName,
                arguments: input + [
                    "-f", "lavfi", "-i", "color=c=black:s=320x180:r=25:d=4",
                    "-vf", "format=rgb24,geq=r='mod(N*\(redStep),256)':g=128:b=64\(filters),format=yuv420p",
                    "-g", "25", "-sc_threshold", "0",
                ] + codec
            )
        }

        func open() async throws -> any MediaEngine {
            opensWithAVFoundation
                ? try await AVFoundationEngine.open(try make())
                : try await FFmpegEngine.open(try make())
        }
    }

    // Steps of 16 survive lossy coding; the level wraps every 16 frames, away from the frames tested.
    static let redStep = 16
    static let colorTolerance = 4.0

    static func expectedRed(frame: Int) -> Double {
        Double((frame * redStep) % 256)
    }

    private static let h264 = ["-c:v", "libx264", "-bf", "2"]
    private static let hevc = ["-c:v", "libx265", "-tag:v", "hvc1", "-x265-params", "log-level=error:bframes=2"]

    static let h264MKV = Movie(fileName: "frames-h264.mkv", codec: h264, opensWithAVFoundation: false)
    static let h264TS = Movie(fileName: "frames-h264.ts", codec: h264, opensWithAVFoundation: false)
    static let vp9WebM = Movie(
        fileName: "frames-vp9.webm", codec: ["-c:v", "libvpx-vp9"], opensWithAVFoundation: false)
    static let h264MOV = Movie(fileName: "frames-h264.mov", codec: h264, opensWithAVFoundation: true)
    static let hevcMOV = Movie(fileName: "frames-hevc.mov", codec: hevc, opensWithAVFoundation: true)

    static let numbered = [h264MKV, h264TS, vp9WebM, h264MOV, hevcMOV]

    static let rotated = [
        Movie(fileName: "frames-rotated.mkv", codec: h264, input: rotation, opensWithAVFoundation: false),
        Movie(fileName: "frames-rotated.mov", codec: h264, input: rotation, opensWithAVFoundation: true),
    ]

    // Pixels twice as wide as tall: 320×180 stored, 640×180 shown.
    static let anamorphic = [
        Movie(fileName: "frames-wide.mkv", codec: h264, filters: ",setsar=2", opensWithAVFoundation: false),
        Movie(fileName: "frames-wide.mov", codec: h264, filters: ",setsar=2", opensWithAVFoundation: true),
    ]

    private static let rotation = ["-display_rotation:v", "90"]

    /// One second of flat grey at PQ code 0.58, the HDR reference white of 203 nits.
    static func pqGrey(_ fileName: String) throws -> URL {
        try ExternalFFmpeg.make(
            fileName,
            arguments: [
                "-f", "lavfi", "-i", "color=c=gray:s=320x180:r=25:d=1",
                "-vf", "format=yuv420p10le,geq=lum=572:cb=512:cr=512",
                "-pix_fmt", "yuv420p10le", "-c:v", "libx265", "-tag:v", "hvc1",
                "-x265-params", "log-level=error:colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc",
                "-color_primaries", "bt2020", "-color_trc", "smpte2084", "-colorspace", "bt2020nc",
            ]
        )
    }
}

enum ImageProbe {
    /// Mean of each channel, read in the image's own color space so no conversion shifts the values.
    static func averageColor(of image: CGImage) -> (red: Double, green: Double, blue: Double) {
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpaceCreateDeviceRGB()
        pixels.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        var sums = [0.0, 0.0, 0.0]
        for index in stride(from: 0, to: pixels.count, by: 4) {
            for channel in 0..<3 { sums[channel] += Double(pixels[index + channel]) }
        }
        let count = Double(width * height)
        return (sums[0] / count, sums[1] / count, sums[2] / count)
    }
}

@Suite(.enabled(if: ExternalFFmpeg.isAvailable)) struct EngineFrameImageTests {
    // Frames start every 40 ms; the key frame before 1.5 s is at 1 s, so these decode through a GOP.
    static let exactFrames: [(time: TimeInterval, frame: Int)] = [
        (0, 0), (0.5, 12), (1.5, 37), (1.519_9, 37), (1.52, 38), (1.539, 38), (2.0, 50), (3.99, 99),
    ]

    @Test(arguments: FrameFixtures.numbered)
    func returnsFrameOnScreenAtTime(_ movie: FrameFixtures.Movie) async throws {
        let engine = try await movie.open()
        for (time, frame) in Self.exactFrames {
            let image = try #require(await engine.frameImage(at: time), "no image at \(time)")
            #expect(image.width == 320 && image.height == 180)
            let red = ImageProbe.averageColor(of: image).red
            #expect(
                abs(red - FrameFixtures.expectedRed(frame: frame)) < FrameFixtures.colorTolerance,
                "at \(time) expected frame \(frame), red \(red)")
        }
    }

    @Test(arguments: FrameFixtures.numbered)
    func endOfFileShowsLastFrame(_ movie: FrameFixtures.Movie) async throws {
        let engine = try await movie.open()
        let image = try #require(await engine.frameImage(at: engine.info.duration))
        let red = ImageProbe.averageColor(of: image).red
        #expect(abs(red - FrameFixtures.expectedRed(frame: 99)) < FrameFixtures.colorTolerance)
    }

    @Test(arguments: FrameFixtures.rotated)
    func turnsRotatedVideo(_ movie: FrameFixtures.Movie) async throws {
        let engine = try await movie.open()
        let image = try #require(await engine.frameImage(at: 1.52))
        #expect(image.width == 180 && image.height == 320)
        let red = ImageProbe.averageColor(of: image).red
        #expect(abs(red - FrameFixtures.expectedRed(frame: 38)) < FrameFixtures.colorTolerance)
    }

    @Test(arguments: FrameFixtures.anamorphic)
    func stretchesNonSquarePixels(_ movie: FrameFixtures.Movie) async throws {
        let engine = try await movie.open()
        let image = try #require(await engine.frameImage(at: 1))
        #expect(image.width == 640 && image.height == 180)
    }

    @Test(arguments: [false, true])
    func toneMapsHDRWithoutWashingOut(withAVFoundation: Bool) async throws {
        let url = try FrameFixtures.pqGrey(withAVFoundation ? "pq-grey.mov" : "pq-grey.mkv")
        let engine =
            withAVFoundation ? try await AVFoundationEngine.open(url) : try await FFmpegEngine.open(url)
        let image = try #require(await engine.frameImage(at: 0.5))
        let color = ImageProbe.averageColor(of: image)
        // Read as SDR, the code value would be a dull grey of about 148.
        #expect(color.green > 180, "green \(color.green)")
        #expect(abs(color.red - color.green) < 8 && abs(color.blue - color.green) < 8)
    }

    @Test func audioHasNoFrames() async throws {
        let ffmpeg = try await FFmpegEngine.open(try FFmpegFixtures.opus.make())
        #expect(await ffmpeg.frameImage(at: 1) == nil)
        let native = try await AVFoundationEngine.open(try await TestMedia.audio())
        #expect(await native.frameImage(at: 1) == nil)
    }

    @Test func cancelledRequestReturnsNothing() async throws {
        let engine = try await FrameFixtures.h264MKV.open()
        let task = Task { await engine.frameImage(at: 3.5) }
        task.cancel()
        #expect(await task.value == nil)
    }
}
