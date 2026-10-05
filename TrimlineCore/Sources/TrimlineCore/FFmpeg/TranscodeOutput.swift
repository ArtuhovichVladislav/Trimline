import libavcodec
import libavformat
import libavutil

extension RemuxOutput {
    /// Encoders have to put their parameter sets into the stream header for these containers.
    var needsGlobalHeader: Bool {
        guard let format else { return false }
        return format.pointee.flags & AVFMT_GLOBALHEADER != 0
    }

    func addStream(
        encodedBy encoder: UnsafeMutablePointer<AVCodecContext>, source: UnsafeMutablePointer<AVStream>
    ) throws(FFmpegError) -> Int {
        guard let stream = avformat_new_stream(context, nil), let parameters = stream.pointee.codecpar else {
            throw .outOfMemory
        }
        try FFmpegError.check(avcodec_parameters_from_context(parameters, encoder))
        if parameters.pointee.codec_id == AV_CODEC_ID_HEVC, parameters.pointee.extradata_size > 0,
            let table = format?.pointee.codec_tag, av_codec_get_id(table, Self.hvc1) == AV_CODEC_ID_HEVC
        {
            // movenc defaults to hev1, which AVFoundation and QuickTime refuse to open.
            parameters.pointee.codec_tag = Self.hvc1
        }
        stream.pointee.time_base = encoder.pointee.time_base
        stream.pointee.sample_aspect_ratio = encoder.pointee.sample_aspect_ratio
        stream.pointee.avg_frame_rate = source.pointee.avg_frame_rate
        stream.pointee.disposition = source.pointee.disposition
        try FFmpegError.check(av_dict_copy(&stream.pointee.metadata, source.pointee.metadata, 0))
        if let input = source.pointee.codecpar {
            try Self.copyPresentationSideData(from: input, to: parameters)
        }
        return Int(stream.pointee.index)
    }

    // MARK: Private

    private static let hvc1 = "hvc1".utf8.reversed().reduce(UInt32(0)) { $0 << 8 | UInt32($1) }

    // Rotation and HDR mastering survive re-encoding; codec-specific records (Dolby Vision, CPB) do not.
    private static let presentationSideData: [AVPacketSideDataType] = [
        AV_PKT_DATA_DISPLAYMATRIX, AV_PKT_DATA_MASTERING_DISPLAY_METADATA, AV_PKT_DATA_CONTENT_LIGHT_LEVEL,
        AV_PKT_DATA_STEREO3D, AV_PKT_DATA_SPHERICAL,
    ]

    private static func copyPresentationSideData(
        from input: UnsafeMutablePointer<AVCodecParameters>, to output: UnsafeMutablePointer<AVCodecParameters>
    ) throws(FFmpegError) {
        for type in presentationSideData {
            guard
                let entry = av_packet_side_data_get(
                    input.pointee.coded_side_data, input.pointee.nb_coded_side_data, type),
                let data = entry.pointee.data
            else { continue }
            guard
                let copy = av_packet_side_data_new(
                    &output.pointee.coded_side_data, &output.pointee.nb_coded_side_data, type, entry.pointee.size, 0),
                let target = copy.pointee.data
            else { throw .outOfMemory }
            target.update(from: data, count: entry.pointee.size)
        }
    }
}
