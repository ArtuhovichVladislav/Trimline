import libavcodec
import libavformat
import libavutil

/// The FLAC muxer rewrites STREAMINFO at the end only from what packets carry, so a copied clip would
/// keep the source's sample count and checksum. Every packet carries the count so far instead.
struct FLACStreamInfo {
    static let muxer = "flac"
    private static let size = 34
    private static let totalSamplesOffset = 13
    private static let checksumRange = 18..<34

    private var bytes: [UInt8]
    private let sampleTimeBase: AVRational
    private var samples: Int64 = 0

    init?(stream: UnsafeMutablePointer<AVStream>) {
        guard let parameters = stream.pointee.codecpar?.pointee, parameters.codec_id == AV_CODEC_ID_FLAC,
            parameters.extradata_size == Self.size, let extradata = parameters.extradata, parameters.sample_rate > 0
        else { return nil }
        bytes = Array(UnsafeBufferPointer(start: extradata, count: Self.size))
        bytes.replaceSubrange(Self.checksumRange, with: repeatElement(0, count: Self.checksumRange.count))
        sampleTimeBase = AVRational(num: 1, den: parameters.sample_rate)
    }

    /// Call before the packet is moved to the output time base.
    mutating func attach(to packet: Packet, timeBase: AVRational) throws(FFmpegError) {
        samples += av_rescale_q(max(0, packet.duration), timeBase, sampleTimeBase)
        // 36 bits: the low nibble of byte 13, then four whole bytes.
        let offset = Self.totalSamplesOffset
        bytes[offset] = bytes[offset] & 0xF0 | UInt8(truncatingIfNeeded: samples >> 32) & 0x0F
        for index in 1...4 {
            bytes[offset + index] = UInt8(truncatingIfNeeded: samples >> (8 * (4 - index)))
        }
        guard let data = av_packet_new_side_data(packet.pointer, AV_PKT_DATA_NEW_EXTRADATA, bytes.count) else {
            throw .outOfMemory
        }
        data.update(from: bytes, count: bytes.count)
    }
}

/// FLAC frames carry their own frame (or sample) number. Players seek by it, so a clip renumbers its
/// frames from zero, which changes the header length and both checksums.
struct FLACFrameNumbers {
    private static let headerPrefixLength = 4
    private static let crcLength = 2
    private var first: UInt64?

    mutating func renumber(_ packet: Packet) throws(FFmpegError) {
        guard let data = packet.pointer.pointee.data, packet.size > Self.headerPrefixLength + Self.crcLength else {
            return
        }
        let bytes = Array(UnsafeBufferPointer(start: data, count: packet.size))
        guard let header = FLACFrameHeader(bytes) else { return }
        let base = first ?? header.number
        first = base
        guard header.number >= base else { return }
        let frame = header.rebuilt(bytes, number: header.number - base)
        try FFmpegError.check(av_packet_make_writable(packet.pointer))
        let difference = Int32(frame.count) - packet.pointer.pointee.size
        if difference > 0 {
            try FFmpegError.check(av_grow_packet(packet.pointer, difference))
        } else if difference < 0 {
            av_shrink_packet(packet.pointer, Int32(frame.count))
        }
        packet.pointer.pointee.data.update(from: frame, count: frame.count)
    }
}

private struct FLACFrameHeader {
    private static let syncMask: UInt8 = 0xFE
    private static let syncSecondByte: UInt8 = 0xF8

    let number: UInt64
    private let numberRange: Range<Int>
    private let headerEnd: Int

    init?(_ bytes: [UInt8]) {
        guard bytes[0] == 0xFF, bytes[1] & Self.syncMask == Self.syncSecondByte else { return nil }
        let start = 4
        let leadingOnes = (~bytes[start]).leadingZeroBitCount
        let length = leadingOnes == 0 ? 1 : leadingOnes
        guard length <= 7, leadingOnes != 1, bytes.count > start + length else { return nil }
        var value = UInt64(bytes[start] & (0xFF >> (length == 1 ? 1 : length + 1)))
        for byte in bytes[(start + 1)..<(start + length)] {
            value = value << 6 | UInt64(byte & 0x3F)
        }
        number = value
        numberRange = start..<(start + length)
        let blockSizeCode = bytes[2] >> 4
        let sampleRateCode = bytes[2] & 0x0F
        let blockSizeBytes = blockSizeCode == 6 ? 1 : blockSizeCode == 7 ? 2 : 0
        let sampleRateBytes = sampleRateCode == 12 ? 1 : (sampleRateCode == 13 || sampleRateCode == 14) ? 2 : 0
        headerEnd = numberRange.upperBound + blockSizeBytes + sampleRateBytes
        guard bytes.count > headerEnd + 2 else { return nil }
    }

    /// The frame with a new number, its header checksum after the header and the frame checksum at the end.
    func rebuilt(_ bytes: [UInt8], number: UInt64) -> [UInt8] {
        var header = Array(bytes[..<numberRange.lowerBound]) + Self.encode(number)
        header += bytes[numberRange.upperBound..<headerEnd]
        header.append(UInt8(truncatingIfNeeded: FLACChecksum.header.compute(header)))
        var frame = header + bytes[(headerEnd + 1)..<(bytes.count - 2)]
        let crc = FLACChecksum.frame.compute(frame)
        frame += [UInt8(truncatingIfNeeded: crc >> 8), UInt8(truncatingIfNeeded: crc)]
        return frame
    }

    // The same variable-length coding as UTF-8, extended to 36 bits.
    private static func encode(_ value: UInt64) -> [UInt8] {
        guard value >= 0x80 else { return [UInt8(value)] }
        let limits: [UInt64] = [0x800, 0x1_0000, 0x20_0000, 0x400_0000, 0x8000_0000]
        let length = (limits.firstIndex { value < $0 } ?? limits.count) + 2
        var bytes = (1..<length).reversed().map { UInt8(0x80 | (value >> (6 * UInt64($0 - 1))) & 0x3F) }
        let lead =
            UInt8(truncatingIfNeeded: 0xFF00 >> length) | UInt8(truncatingIfNeeded: value >> (6 * UInt64(length - 1)))
        bytes.insert(lead, at: 0)
        return bytes
    }
}

/// The CRCs of the FLAC format, most significant bit first, starting from zero.
private struct FLACChecksum: Sendable {
    static let header = FLACChecksum(polynomial: 0x07, width: 8)
    static let frame = FLACChecksum(polynomial: 0x8005, width: 16)

    private let table: [UInt16]
    private let width: Int

    private init(polynomial: UInt16, width: Int) {
        self.width = width
        let topBit: UInt16 = 1 << (width - 1)
        let mask: UInt16 = width == 16 ? 0xFFFF : (1 << width) - 1
        table = (0..<256).map { byte in
            var value = UInt16(byte) << (width - 8)
            for _ in 0..<8 {
                value = value & topBit != 0 ? (value << 1) ^ polynomial : value << 1
            }
            return value & mask
        }
    }

    func compute(_ bytes: [UInt8]) -> UInt16 {
        bytes.reduce(UInt16(0)) { crc, byte in
            let index = Int(UInt8(truncatingIfNeeded: crc >> (width - 8)) ^ byte)
            return width == 16 ? (crc << 8) ^ table[index] : table[index]
        }
    }
}
