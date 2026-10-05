import CoreMedia
import VideoToolbox
import libavcodec
import libavutil

/// Describes H.264 and HEVC streams to VideoToolbox so the display layer can decode them on the GPU.
struct PlaybackVideoFormat {
    let description: CMVideoFormatDescription
    /// Packets carry start codes and must be rewritten with length prefixes.
    let usesStartCodes: Bool
    /// The stream's own parameter sets, when they can be read from its header.
    let bitstream: NALBitstream?
    private let codec: Codec

    private typealias Codec = NALBitstream.Codec

    /// Returns `nil` for other codecs and for streams VideoToolbox can't decode, such as 10-bit H.264.
    init?(stream: Demuxer.Stream, pixelAspect: AVRational) {
        let codec: Codec
        switch stream.codecID {
        case AV_CODEC_ID_H264: codec = .h264
        case AV_CODEC_ID_HEVC: codec = .hevc
        default: return nil
        }
        let parameters = stream.parameters.pointee
        guard let data = parameters.extradata, parameters.extradata_size > 0 else { return nil }
        let extradata = Array(UnsafeBufferPointer(start: data, count: Int(parameters.extradata_size)))
        usesStartCodes = PlaybackNALUnits.isAnnexB(extradata)

        let made =
            usesStartCodes
            ? Self.fromParameterSets(in: extradata, codec: codec)
            : Self.fromAtom(extradata, codec: codec, stream: stream, pixelAspect: pixelAspect)
        guard let made, Self.canDecode(made) else { return nil }
        description = made
        self.codec = codec
        bitstream = NALBitstream(parameters: parameters)
    }

    /// A description for parameter sets that arrive inside the stream. VideoToolbox's HEVC decoder refuses
    /// sets that differ from its description, as in a smart-cut clip whose head was encoded again.
    func description(for parameterSets: [[UInt8]]) -> CMVideoFormatDescription? {
        Self.fromParameterSets(parameterSets, codec: codec)
    }

    private static func fromAtom(
        _ atom: [UInt8], codec: Codec, stream: Demuxer.Stream, pixelAspect: AVRational
    ) -> CMVideoFormatDescription? {
        var extensions: [CFString: Any] = [
            kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms: [codec.atomName: Data(atom)]
        ]
        if pixelAspect.num > 0, pixelAspect.den > 0, pixelAspect.num != pixelAspect.den {
            extensions[kCMFormatDescriptionExtension_PixelAspectRatio] = [
                kCMFormatDescriptionKey_PixelAspectRatioHorizontalSpacing: pixelAspect.num,
                kCMFormatDescriptionKey_PixelAspectRatioVerticalSpacing: pixelAspect.den,
            ]
        }
        var description: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: nil, codecType: codec.codecType, width: Int32(stream.width), height: Int32(stream.height),
            extensions: extensions as CFDictionary, formatDescriptionOut: &description)
        return status == noErr ? description : nil
    }

    private static func fromParameterSets(in extradata: [UInt8], codec: Codec) -> CMVideoFormatDescription? {
        let sets = extradata.withUnsafeBytes { bytes in
            PlaybackNALUnits.units(inAnnexB: bytes).filter { codec.isParameterSet(bytes[$0.lowerBound]) }
                .map { Array(bytes[$0]) }
        }
        return fromParameterSets(sets, codec: codec)
    }

    private static func fromParameterSets(_ sets: [[UInt8]], codec: Codec) -> CMVideoFormatDescription? {
        guard !sets.isEmpty else { return nil }
        let joined = sets.flatMap { $0 }
        let sizes = sets.map(\.count)
        let offsets = sizes.reduce(into: [0]) { $0.append($0[$0.count - 1] + $1) }.dropLast()
        return joined.withUnsafeBufferPointer { buffer -> CMVideoFormatDescription? in
            guard let base = buffer.baseAddress else { return nil }
            let pointers = offsets.map { base + $0 }
            let headerLength = Int32(PlaybackNALUnits.lengthPrefixSize)
            var description: CMVideoFormatDescription?
            let status =
                switch codec {
                case .h264:
                    CMVideoFormatDescriptionCreateFromH264ParameterSets(
                        allocator: nil, parameterSetCount: sets.count, parameterSetPointers: pointers,
                        parameterSetSizes: sizes, nalUnitHeaderLength: headerLength, formatDescriptionOut: &description)
                case .hevc:
                    CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                        allocator: nil, parameterSetCount: sets.count, parameterSetPointers: pointers,
                        parameterSetSizes: sizes, nalUnitHeaderLength: headerLength, extensions: nil,
                        formatDescriptionOut: &description)
                }
            return status == noErr ? description : nil
        }
    }

    // The display layer reports a failed decode only after frames go missing; asking up front lets
    // such streams fall back to libavcodec instead.
    private static func canDecode(_ description: CMVideoFormatDescription) -> Bool {
        var session: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: nil, formatDescription: description, decoderSpecification: nil,
            imageBufferAttributes: nil, outputCallback: nil, decompressionSessionOut: &session)
        if let session {
            VTDecompressionSessionInvalidate(session)
        }
        return status == noErr
    }
}

extension NALBitstream.Codec {
    fileprivate var codecType: CMVideoCodecType {
        switch self {
        case .h264: kCMVideoCodecType_H264
        case .hevc: kCMVideoCodecType_HEVC
        }
    }

    fileprivate var atomName: String {
        switch self {
        case .h264: "avcC"
        case .hevc: "hvcC"
        }
    }
}
