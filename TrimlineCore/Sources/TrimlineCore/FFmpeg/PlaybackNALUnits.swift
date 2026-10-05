import Foundation

/// H.264 and HEVC bitstreams come either with start codes (Annex B, as in MPEG-TS and AVI)
/// or with length prefixes (as in MP4 and Matroska); VideoToolbox only takes the latter.
enum PlaybackNALUnits {
    static let lengthPrefixSize = 4

    private static let shortStartCode: [UInt8] = [0, 0, 1]

    static func isAnnexB(_ bytes: [UInt8]) -> Bool {
        bytes.starts(with: shortStartCode) || bytes.starts(with: [0] + shortStartCode)
    }

    /// The NAL units between start codes, without the start codes themselves.
    static func units(inAnnexB bytes: UnsafeRawBufferPointer) -> [Range<Int>] {
        var starts: [Int] = []
        var index = 0
        while index + shortStartCode.count <= bytes.count {
            if bytes[index] == 0, bytes[index + 1] == 0, bytes[index + 2] == 1 {
                starts.append(index + shortStartCode.count)
                index += shortStartCode.count
            } else {
                index += 1
            }
        }
        return starts.enumerated().compactMap { position, start in
            var end = position + 1 < starts.count ? starts[position + 1] - shortStartCode.count : bytes.count
            // The zero bytes before the next start code are padding or part of a four-byte start code.
            while end > start, bytes[end - 1] == 0 { end -= 1 }
            return end > start ? start..<end : nil
        }
    }

    static func lengthPrefixed(fromAnnexB bytes: UnsafeRawBufferPointer) -> [UInt8] {
        let units = units(inAnnexB: bytes)
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count + units.count * lengthPrefixSize)
        for unit in units {
            let length = UInt32(unit.count).bigEndian
            withUnsafeBytes(of: length) { output.append(contentsOf: $0) }
            output.append(contentsOf: bytes[unit])
        }
        return output
    }
}
