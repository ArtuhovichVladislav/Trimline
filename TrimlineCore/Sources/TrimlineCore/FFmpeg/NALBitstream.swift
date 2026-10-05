import libavcodec
import libavutil

/// An H.264 or HEVC stream as NAL units: its parameter sets and the packet surgery of a smart cut.
/// VideoToolbox numbers its parameter sets from zero, like nearly every encoder, so the sets of an encoded
/// part replace the source's in the decoder. Every copied key frame therefore carries the source's sets
/// again: a decoder that has shown the head and then seeks into the copy needs them.
struct NALBitstream {
    enum Codec {
        case h264
        case hevc
    }

    let codec: Codec
    /// Packets carry four-byte length prefixes (MP4, Matroska) rather than start codes (MPEG-TS).
    let isLengthPrefixed: Bool
    /// The source's parameter sets, in the order they go into a stream.
    let parameterSets: [[UInt8]]

    private static let lengthPrefixSize = PlaybackNALUnits.lengthPrefixSize
    private static let startCode: [UInt8] = [0, 0, 0, 1]

    init?(parameters: AVCodecParameters) {
        switch parameters.codec_id {
        case AV_CODEC_ID_H264: codec = .h264
        case AV_CODEC_ID_HEVC: codec = .hevc
        default: return nil
        }
        guard let data = parameters.extradata, parameters.extradata_size > 0 else { return nil }
        let extradata = Array(UnsafeBufferPointer(start: data, count: Int(parameters.extradata_size)))
        let units: [[UInt8]]?
        if PlaybackNALUnits.isAnnexB(extradata) {
            isLengthPrefixed = false
            units = extradata.withUnsafeBytes { bytes in
                PlaybackNALUnits.units(inAnnexB: bytes).map { Array(bytes[$0]) }
            }
        } else {
            isLengthPrefixed = true
            units = codec == .h264 ? Self.avcConfigurationUnits(extradata) : Self.hevcConfigurationUnits(extradata)
        }
        guard let sets = Self.completeParameterSets(units ?? [], codec: codec) else { return nil }
        parameterSets = sets
    }

    /// The parameter sets a packet of this stream carries, if it carries a whole set of them.
    func parameterSets(in bytes: UnsafeRawBufferPointer) -> [[UInt8]]? {
        guard let units = units(in: bytes) else { return nil }
        let sets = units.filter { codec.isParameterSet(bytes[$0.lowerBound]) }.map { Array(bytes[$0]) }
        return Self.completeParameterSets(sets, codec: codec)
    }

    /// An IDR picture in H.264; any random access picture in HEVC, whose leading pictures the copy leaves out.
    func startsCleanly(_ packet: Packet) -> Bool {
        withUnits(of: packet) { bytes, units in
            guard let first = units.first(where: { codec.isPicture(bytes[$0.lowerBound]) }) else { return false }
            return codec.startsCleanly(bytes[first.lowerBound])
        } ?? false
    }

    /// The first copied picture: its own parameter sets in front and, for HEVC, a clean random access picture
    /// turned into a broken link one, which may start a new sequence with new parameter sets. Its leading
    /// pictures are gone from the copy, so the "no leading pictures" kind is the honest one.
    func rewriteJunction(_ packet: Packet) throws(FFmpegError) {
        try rewrite(packet) { unit in
            guard codec == .hevc, codec.type(of: unit[0]) == Codec.hevcCleanRandomAccess else { return unit }
            var changed = unit
            changed[0] = unit[0] & 0x81 | Codec.hevcBrokenLinkWithoutLeading << 1
            return changed
        }
    }

    /// Puts the source's parameter sets in front of a copied key frame that lacks them.
    func addParameterSets(to packet: Packet) throws(FFmpegError) {
        try rewrite(packet) { $0 }
    }

    /// VideoToolbox writes start codes; the copied stream may use length prefixes.
    func convertEncoded(_ packet: Packet) throws(FFmpegError) {
        guard isLengthPrefixed, let data = packet.pointer.pointee.data else { return }
        let converted = PlaybackNALUnits.lengthPrefixed(
            fromAnnexB: UnsafeRawBufferPointer(start: data, count: packet.size))
        try replace(packet, with: converted)
    }

    // MARK: Private

    private func withUnits<Result>(
        of packet: Packet, _ body: (UnsafeRawBufferPointer, [Range<Int>]) -> Result
    ) -> Result? {
        guard let data = packet.pointer.pointee.data else { return nil }
        let bytes = UnsafeRawBufferPointer(start: data, count: packet.size)
        guard let units = units(in: bytes) else { return nil }
        return body(bytes, units)
    }

    private func units(in bytes: UnsafeRawBufferPointer) -> [Range<Int>]? {
        isLengthPrefixed ? Self.units(inLengthPrefixed: bytes) : PlaybackNALUnits.units(inAnnexB: bytes)
    }

    /// Every type of parameter set, in stream order, or `nil` when one is missing.
    private static func completeParameterSets(_ units: [[UInt8]], codec: Codec) -> [[UInt8]]? {
        let sets = units.filter { !$0.isEmpty && codec.isParameterSet($0[0]) }
        guard codec.parameterSetTypes.allSatisfy({ type in sets.contains { codec.type(of: $0[0]) == type } }) else {
            return nil
        }
        return codec.parameterSetTypes.flatMap { type in sets.filter { codec.type(of: $0[0]) == type } }
    }

    private static func units(inLengthPrefixed bytes: UnsafeRawBufferPointer) -> [Range<Int>]? {
        var units: [Range<Int>] = []
        var offset = 0
        while offset + Self.lengthPrefixSize <= bytes.count {
            let length = bytes[offset..<(offset + Self.lengthPrefixSize)].reduce(0) { $0 << 8 | Int($1) }
            let start = offset + Self.lengthPrefixSize
            guard length > 0, start + length <= bytes.count else { return nil }
            units.append(start..<(start + length))
            offset = start + length
        }
        return units
    }

    /// Rebuilds the packet unit by unit, with the parameter sets after any access unit delimiter.
    private func rewrite(_ packet: Packet, unit transform: ([UInt8]) -> [UInt8]) throws(FFmpegError) {
        let rebuilt: [UInt8]? = withUnits(of: packet) { bytes, units in
            let pieces = units.map { Array(bytes[$0]) }
            let hasSets = pieces.contains { codec.isParameterSet($0[0]) }
            let position = pieces.firstIndex { !codec.isDelimiter($0[0]) } ?? pieces.count
            var output: [UInt8] = []
            output.reserveCapacity(bytes.count + parameterSets.reduce(0) { $0 + $1.count + Self.lengthPrefixSize })
            for (index, piece) in pieces.enumerated() {
                if index == position, !hasSets {
                    parameterSets.forEach { append($0, to: &output) }
                }
                append(transform(piece), to: &output)
            }
            return output
        }
        guard let rebuilt else { throw .invalidData }
        try replace(packet, with: rebuilt)
    }

    private func append(_ unit: [UInt8], to output: inout [UInt8]) {
        if isLengthPrefixed {
            withUnsafeBytes(of: UInt32(unit.count).bigEndian) { output.append(contentsOf: $0) }
        } else {
            output.append(contentsOf: Self.startCode)
        }
        output.append(contentsOf: unit)
    }

    private func replace(_ packet: Packet, with bytes: [UInt8]) throws(FFmpegError) {
        try FFmpegError.check(av_packet_make_writable(packet.pointer))
        let difference = Int32(bytes.count) - packet.pointer.pointee.size
        if difference > 0 {
            try FFmpegError.check(av_grow_packet(packet.pointer, difference))
        } else if difference < 0 {
            av_shrink_packet(packet.pointer, Int32(bytes.count))
        }
        packet.pointer.pointee.data.update(from: bytes, count: bytes.count)
    }

    /// AVCDecoderConfigurationRecord (ISO/IEC 14496-15): sequence and then picture parameter sets.
    private static func avcConfigurationUnits(_ record: [UInt8]) -> [[UInt8]]? {
        guard record.count > 6, record[0] == 1, record[4] & 0x03 == 0x03 else { return nil }
        var reader = RecordReader(bytes: record, offset: 5)
        guard let sequenceCount = reader.byte(), let sequenceSets = reader.units(Int(sequenceCount & 0x1F)),
            let pictureCount = reader.byte(), let pictureSets = reader.units(Int(pictureCount))
        else { return nil }
        return sequenceSets + pictureSets
    }

    /// HEVCDecoderConfigurationRecord: arrays of NAL units, each array of one type.
    private static func hevcConfigurationUnits(_ record: [UInt8]) -> [[UInt8]]? {
        guard record.count > 22, record[0] == 1, record[21] & 0x03 == 0x03 else { return nil }
        var reader = RecordReader(bytes: record, offset: 22)
        guard let arrayCount = reader.byte() else { return nil }
        var units: [[UInt8]] = []
        for _ in 0..<arrayCount {
            guard reader.byte() != nil, let count = reader.uint16(), let array = reader.units(Int(count)) else {
                return nil
            }
            units += array
        }
        return units
    }
}

extension NALBitstream.Codec {
    // NAL unit types from the H.264 and HEVC specifications.
    fileprivate static let hevcCleanRandomAccess: UInt8 = 21
    fileprivate static let hevcBrokenLinkWithoutLeading: UInt8 = 18
    private static let h264IDR: UInt8 = 5
    private static let h264Delimiter: UInt8 = 9
    private static let hevcDelimiter: UInt8 = 35
    private static let hevcRandomAccess: ClosedRange<UInt8> = 16...21

    var parameterSetTypes: [UInt8] {
        switch self {
        case .h264: [7, 8]
        case .hevc: [32, 33, 34]
        }
    }

    func type(of header: UInt8) -> UInt8 {
        switch self {
        case .h264: header & 0x1F
        case .hevc: (header >> 1) & 0x3F
        }
    }

    func isParameterSet(_ header: UInt8) -> Bool { parameterSetTypes.contains(type(of: header)) }

    func isDelimiter(_ header: UInt8) -> Bool {
        type(of: header) == (self == .h264 ? Self.h264Delimiter : Self.hevcDelimiter)
    }

    func isPicture(_ header: UInt8) -> Bool {
        switch self {
        case .h264: (1...5).contains(type(of: header))
        case .hevc: type(of: header) < 32
        }
    }

    func startsCleanly(_ header: UInt8) -> Bool {
        switch self {
        case .h264: type(of: header) == Self.h264IDR
        case .hevc: Self.hevcRandomAccess.contains(type(of: header))
        }
    }
}

private struct RecordReader {
    let bytes: [UInt8]
    var offset: Int

    mutating func byte() -> UInt8? {
        guard offset < bytes.count else { return nil }
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func uint16() -> Int? {
        guard let high = byte(), let low = byte() else { return nil }
        return Int(high) << 8 | Int(low)
    }

    mutating func units(_ count: Int) -> [[UInt8]]? {
        var units: [[UInt8]] = []
        for _ in 0..<count {
            guard let length = uint16(), offset + length <= bytes.count else { return nil }
            units.append(Array(bytes[offset..<(offset + length)]))
            offset += length
        }
        return units
    }
}
