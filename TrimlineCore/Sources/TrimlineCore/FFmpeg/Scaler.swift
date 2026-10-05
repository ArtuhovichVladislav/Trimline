import CoreVideo
import libavutil
import libswscale

/// Converts decoded video frames into BGRA pixel buffers of a chosen size.
final class Scaler {
    private var context: OpaquePointer?

    deinit {
        sws_freeContext(context)
    }

    /// Scales `frame` into `pixelBuffer`, which must be 32BGRA; the buffer's size is the output size.
    func scale(_ frame: Frame, into pixelBuffer: CVPixelBuffer) throws(FFmpegError) {
        let source = frame.pointer.pointee
        let width = Int32(CVPixelBufferGetWidth(pixelBuffer))
        let height = Int32(CVPixelBufferGetHeight(pixelBuffer))
        context = sws_getCachedContext(
            context, source.width, source.height, AVPixelFormat(rawValue: source.format),
            width, height, AV_PIX_FMT_BGRA, SWS_BILINEAR, nil, nil, nil)
        guard let context else { throw .invalidData }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { throw .invalidData }
        var destination: [UnsafeMutablePointer<UInt8>?] = [base.assumingMemoryBound(to: UInt8.self), nil, nil, nil]
        var destinationStride: [Int32] = [Int32(CVPixelBufferGetBytesPerRow(pixelBuffer)), 0, 0, 0]
        var planes: [UnsafePointer<UInt8>?] = [source.data.0, source.data.1, source.data.2, source.data.3].map {
            $0.map { UnsafePointer($0) }
        }
        var strides = [source.linesize.0, source.linesize.1, source.linesize.2, source.linesize.3]
        try FFmpegError.check(
            sws_scale(context, &planes, &strides, 0, source.height, &destination, &destinationStride))
    }
}
