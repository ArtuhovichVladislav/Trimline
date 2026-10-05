import libavcodec

/// WavPack blocks carry the index of their first sample, which players take as its time; a clip counts
/// from zero. The block checksum covers only the audio data, so the header can change in place.
struct WavPackBlockNumbers {
    static let muxer = "wv"

    private static let magic = Array("wvpk".utf8)
    private static let headerSize = 32
    private static let sizeOffset = 4
    private static let indexHighOffset = 10
    private static let indexOffset = 16
    private static let chunkHeaderSize = 8
    private var first: UInt64?

    mutating func renumber(_ packet: Packet) throws(FFmpegError) {
        guard packet.size >= Self.headerSize else { return }
        try FFmpegError.check(av_packet_make_writable(packet.pointer))
        guard let data = packet.pointer.pointee.data else { return }
        let bytes = UnsafeMutableBufferPointer(start: data, count: packet.size)
        var offset = 0
        while offset + Self.headerSize <= bytes.count, Array(bytes[offset..<offset + 4]) == Self.magic {
            let index =
                UInt64(bytes[offset + Self.indexHighOffset]) << 32
                | UInt64(read32(bytes, at: offset + Self.indexOffset))
            let base = first ?? index
            first = base
            let renumbered = index >= base ? index - base : index
            bytes[offset + Self.indexHighOffset] = UInt8(truncatingIfNeeded: renumbered >> 32)
            for byte in 0..<4 {
                bytes[offset + Self.indexOffset + byte] = UInt8(truncatingIfNeeded: renumbered >> (8 * UInt64(byte)))
            }
            offset += Int(read32(bytes, at: offset + Self.sizeOffset)) + Self.chunkHeaderSize
        }
    }

    private func read32(_ bytes: UnsafeMutableBufferPointer<UInt8>, at offset: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[offset + $1]) << (8 * UInt32($1)) }
    }
}
