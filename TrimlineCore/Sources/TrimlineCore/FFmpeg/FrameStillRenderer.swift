import CoreGraphics
import CoreImage
import Foundation
import libavutil
import libswscale

// Renders a decoded frame at full size in sRGB, as the player shows it: the YUV matrix and range
// the stream declares, square pixels, rotation. PQ and HLG are tone-mapped to SDR by Core Image;
// read as SDR they would look grey and flat.
enum FrameStillRenderer {
    private enum Transfer {
        case standard
        case perceptualQuantizer
        case hybridLogGamma

        init(_ characteristic: AVColorTransferCharacteristic) {
            switch characteristic {
            case AVCOL_TRC_SMPTE2084: self = .perceptualQuantizer
            case AVCOL_TRC_ARIB_STD_B67: self = .hybridLogGamma
            default: self = .standard
            }
        }

        var pixelFormat: AVPixelFormat { self == .standard ? AV_PIX_FMT_BGRA : AV_PIX_FMT_RGBA64LE }
        var bitsPerComponent: Int { self == .standard ? 8 : 16 }
        var bytesPerPixel: Int { self == .standard ? 4 : 8 }

        var bitmapInfo: CGBitmapInfo {
            self == .standard
                ? CGBitmapInfo(
                    rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
                : CGBitmapInfo(
                    rawValue: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue)
        }

        var colorSpaceName: CFString {
            switch self {
            case .standard: CGColorSpace.sRGB
            case .perceptualQuantizer: CGColorSpace.itur_2100_PQ
            case .hybridLogGamma: CGColorSpace.itur_2100_HLG
            }
        }
    }

    // Untagged video uses the BT.709 matrix from HD up and BT.601 below, as players assume.
    private static let highDefinitionHeight = 720
    private static let rowAlignment = 64
    private static let unity: Int32 = 1 << 16
    private static let fullRangeFormats = Set(
        [AV_PIX_FMT_YUVJ420P, AV_PIX_FMT_YUVJ422P, AV_PIX_FMT_YUVJ444P, AV_PIX_FMT_YUVJ440P, AV_PIX_FMT_YUVJ411P]
            .map(\.rawValue))

    /// `displayAspectRatio` is width over height after rotation and sample aspect ratio.
    static func image(of frame: Frame, quarterTurns: Int, displayAspectRatio: Double?) -> CGImage? {
        guard frame.width > 0, frame.height > 0 else { return nil }
        let isSideways = !quarterTurns.isMultiple(of: 2)
        let aspect = displayAspectRatio.map { isSideways ? 1 / $0 : $0 } ?? Double(frame.width) / Double(frame.height)
        // Non-square pixels widen or narrow the picture; its height stays as decoded.
        let width = max(1, Int((Double(frame.height) * aspect).rounded()))
        let transfer = Transfer(frame.pointer.pointee.color_trc)
        guard let converted = convert(frame, width: width, transfer: transfer) else { return nil }
        guard let image = transfer == .standard ? converted : toneMapped(converted) else { return nil }
        return quarterTurns == 0 ? image : FrameImageRenderer.rotate(image, clockwiseQuarterTurns: quarterTurns)
    }

    // MARK: Private

    private static func convert(_ frame: Frame, width: Int, transfer: Transfer) -> CGImage? {
        let source = frame.pointer.pointee
        let height = frame.height
        guard
            let context = sws_getContext(
                source.width, source.height, AVPixelFormat(rawValue: source.format), Int32(width), Int32(height),
                transfer.pixelFormat, SWS_BICUBIC | SWS_FULL_CHR_H_INT | SWS_ACCURATE_RND, nil, nil, nil)
        else { return nil }
        defer { sws_freeContext(context) }
        let coefficients = sws_getCoefficients(matrix(of: frame))
        let sourceRange: Int32 = isFullRange(frame) ? 1 : 0
        // Fails harmlessly for RGB sources, which have no matrix.
        sws_setColorspaceDetails(context, coefficients, sourceRange, coefficients, 1, 0, unity, unity)

        let bytesPerRow = (width * transfer.bytesPerPixel + rowAlignment - 1) / rowAlignment * rowAlignment
        var pixels = Data(count: bytesPerRow * height)
        let scaled = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let base = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return false }
            var destination: [UnsafeMutablePointer<UInt8>?] = [base, nil, nil, nil]
            var destinationStrides: [Int32] = [Int32(bytesPerRow), 0, 0, 0]
            var planes: [UnsafePointer<UInt8>?] = [source.data.0, source.data.1, source.data.2, source.data.3].map {
                $0.map { UnsafePointer($0) }
            }
            var strides = [source.linesize.0, source.linesize.1, source.linesize.2, source.linesize.3]
            return sws_scale(context, &planes, &strides, 0, source.height, &destination, &destinationStrides) > 0
        }
        guard scaled, let provider = CGDataProvider(data: pixels as CFData),
            let colorSpace = CGColorSpace(name: transfer.colorSpaceName)
        else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: transfer.bitsPerComponent,
            bitsPerPixel: transfer.bytesPerPixel * 8, bytesPerRow: bytesPerRow, space: colorSpace,
            bitmapInfo: transfer.bitmapInfo, provider: provider, decode: nil, shouldInterpolate: false,
            intent: .defaultIntent)
    }

    // Core Image maps HDR into SDR with the ITU-R curve rather than clipping the highlights.
    private static func toneMapped(_ image: CGImage) -> CGImage? {
        guard let sRGB = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let context = CIContext(options: [.cacheIntermediates: false])
        let input = CIImage(cgImage: image)
        return context.createCGImage(input, from: input.extent, format: .BGRA8, colorSpace: sRGB)
    }

    private static func matrix(of frame: Frame) -> Int32 {
        let space = frame.pointer.pointee.colorspace
        guard space != AVCOL_SPC_UNSPECIFIED, space != AVCOL_SPC_RESERVED else {
            return frame.height >= highDefinitionHeight ? SWS_CS_ITU709 : SWS_CS_ITU601
        }
        // The SWS_CS_* constants are AVColorSpace values; sws_getCoefficients falls back for the rest.
        return Int32(space.rawValue)
    }

    private static func isFullRange(_ frame: Frame) -> Bool {
        let source = frame.pointer.pointee
        return source.color_range == AVCOL_RANGE_JPEG || fullRangeFormats.contains(source.format)
    }
}
