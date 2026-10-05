import CoreGraphics
import CoreVideo
import VideoToolbox

// Turns a decoded frame into a CGImage the way it is meant to be seen: rotated and with square pixels.
final class FrameImageRenderer {
    private let scaler = Scaler()
    private let quarterTurns: Int
    private let displayAspectRatio: Double?

    private static let bitsPerComponent = 8

    /// `displayAspectRatio` is width over height after rotation and sample aspect ratio.
    init(quarterTurns: Int, displayAspectRatio: Double?) {
        self.quarterTurns = quarterTurns
        self.displayAspectRatio = displayAspectRatio
    }

    /// At most `height` pixels tall: thumbnails are never upscaled.
    func image(of frame: Frame, height: Int) -> CGImage? {
        guard frame.width > 0, frame.height > 0, height > 0 else { return nil }
        let isSideways = !quarterTurns.isMultiple(of: 2)
        let frameAspect = Double(frame.width) / Double(frame.height)
        let aspect = displayAspectRatio ?? (isSideways ? 1 / frameAspect : frameAspect)
        let outputHeight = min(height, isSideways ? frame.width : frame.height)
        let outputWidth = max(1, Int((Double(outputHeight) * aspect).rounded()))
        let scaled = isSideways ? (outputHeight, outputWidth) : (outputWidth, outputHeight)

        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, scaled.0, scaled.1, kCVPixelFormatType_32BGRA, nil, &buffer)
        guard let buffer, (try? scaler.scale(frame, into: buffer)) != nil else { return nil }
        var image: CGImage?
        VTCreateCGImageFromCVPixelBuffer(buffer, options: nil, imageOut: &image)
        guard let image else { return nil }
        return quarterTurns == 0 ? image : Self.rotate(image, clockwiseQuarterTurns: quarterTurns)
    }

    static func rotate(_ image: CGImage, clockwiseQuarterTurns turns: Int) -> CGImage? {
        let isSideways = !turns.isMultiple(of: 2)
        let width = isSideways ? image.height : image.width
        let height = isSideways ? image.width : image.height
        guard
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: bitsPerComponent, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        // Core Graphics has y pointing up, so a clockwise turn is a negative angle.
        context.translateBy(x: CGFloat(width) / 2, y: CGFloat(height) / 2)
        context.rotate(by: -CGFloat(turns) * .pi / 2)
        let size = CGSize(width: image.width, height: image.height)
        context.draw(image, in: CGRect(origin: CGPoint(x: -size.width / 2, y: -size.height / 2), size: size))
        return context.makeImage()
    }
}
