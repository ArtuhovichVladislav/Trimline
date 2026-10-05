import Foundation
import libavutil

struct FFmpegError: Error, CustomStringConvertible {
    let code: Int32

    // AVERROR_EOF and AVERROR(EAGAIN) are function-like macros that Swift doesn't import.
    static let endOfFile = FFmpegError(tag: Array("EOF ".utf8))
    static let tryAgain = FFmpegError(code: -EAGAIN)
    static let outOfMemory = FFmpegError(code: -ENOMEM)
    static let invalidData = FFmpegError(tag: Array("INDA".utf8))
    static let decoderNotFound = FFmpegError(tag: [0xF8] + Array("DEC".utf8))
    static let encoderNotFound = FFmpegError(tag: [0xF8] + Array("ENC".utf8))

    var isEndOfFile: Bool { code == Self.endOfFile.code }
    var isTryAgain: Bool { code == Self.tryAgain.code }

    init(code: Int32) {
        self.code = code
    }

    /// An FFERRTAG code: four bytes, negated.
    init(tag bytes: [UInt8]) {
        code = -Int32(
            bitPattern: bytes.enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) })
    }

    var description: String {
        var buffer = [CChar](repeating: 0, count: Int(AV_ERROR_MAX_STRING_SIZE))
        av_strerror(code, &buffer, buffer.count)
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// Throws for negative FFmpeg return codes and passes the others through.
    @discardableResult
    static func check(_ result: Int32) throws(FFmpegError) -> Int32 {
        guard result >= 0 else { throw FFmpegError(code: result) }
        return result
    }
}
