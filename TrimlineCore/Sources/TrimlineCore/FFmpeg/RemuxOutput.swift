import Foundation
import libavcodec
import libavformat
import libavutil

/// The clip file being written: an output format context with its own file handle.
final class RemuxOutput {
    let context: UnsafeMutablePointer<AVFormatContext>
    private var isOpen = false

    init(path: String, muxer: String) throws(FFmpegError) {
        var created: UnsafeMutablePointer<AVFormatContext>?
        try FFmpegError.check(avformat_alloc_output_context2(&created, nil, muxer, path))
        guard let created else { throw .outOfMemory }
        context = created
    }

    deinit {
        if isOpen {
            avio_closep(&context.pointee.pb)
        }
        avformat_free_context(context)
    }

    var format: UnsafePointer<AVOutputFormat>? { context.pointee.oformat }

    static func isAvailable(muxer: String) -> Bool {
        av_guess_format(muxer, nil, nil) != nil
    }

    /// Mpeg-TS and others accept equal decode times in a row; most muxers need them strictly increasing.
    var allowsEqualDts: Bool {
        guard let format else { return false }
        return format.pointee.flags & AVFMT_TS_NONSTRICT != 0
    }

    func addStream(copying source: UnsafeMutablePointer<AVStream>) throws(FFmpegError) -> Int {
        guard let stream = avformat_new_stream(context, nil), let input = source.pointee.codecpar,
            let output = stream.pointee.codecpar
        else { throw .outOfMemory }
        try FFmpegError.check(avcodec_parameters_copy(output, input))
        output.pointee.codec_tag = compatibleTag(for: input.pointee)
        stream.pointee.time_base = source.pointee.time_base
        stream.pointee.sample_aspect_ratio = source.pointee.sample_aspect_ratio
        stream.pointee.avg_frame_rate = source.pointee.avg_frame_rate
        stream.pointee.r_frame_rate = source.pointee.r_frame_rate
        stream.pointee.disposition = source.pointee.disposition
        try FFmpegError.check(av_dict_copy(&stream.pointee.metadata, source.pointee.metadata, 0))
        return Int(stream.pointee.index)
    }

    /// Matroska keeps cover art as an attached file rather than a one-frame video track.
    func addAttachment(picture source: UnsafeMutablePointer<AVStream>) throws(FFmpegError) -> Int {
        let picture = source.pointee.attached_pic
        guard let data = picture.data, picture.size > 0 else { throw .invalidData }
        let index = try addStream(copying: source)
        guard let stream = context.pointee.streams[index], let parameters = stream.pointee.codecpar else {
            throw .invalidData
        }
        guard let extradata = av_mallocz(Int(picture.size) + Int(AV_INPUT_BUFFER_PADDING_SIZE)) else {
            throw .outOfMemory
        }
        extradata.copyMemory(from: data, byteCount: Int(picture.size))
        av_freep(&parameters.pointee.extradata)
        parameters.pointee.extradata = extradata.assumingMemoryBound(to: UInt8.self)
        parameters.pointee.extradata_size = picture.size
        parameters.pointee.codec_type = AVMEDIA_TYPE_ATTACHMENT
        stream.pointee.disposition = 0
        if av_dict_get(stream.pointee.metadata, Self.fileNameKey, nil, 0) == nil {
            let name = parameters.pointee.codec_id == AV_CODEC_ID_PNG ? "cover.png" : "cover.jpg"
            try FFmpegError.check(av_dict_set(&stream.pointee.metadata, Self.fileNameKey, name, 0))
        }
        return index
    }

    /// Camera files keep location, make and model in QuickTime metadata keys, which the MOV muxer drops;
    /// it writes the same values under its classic names, and AVFoundation reads both.
    func copyMetadata(from source: UnsafeMutablePointer<AVFormatContext>, mapsCameraKeys: Bool) throws(FFmpegError) {
        try FFmpegError.check(av_dict_copy(&context.pointee.metadata, source.pointee.metadata, 0))
        guard mapsCameraKeys else { return }
        for (cameraKey, key) in Self.cameraKeys where av_dict_get(context.pointee.metadata, key, nil, 0) == nil {
            guard let value = av_dict_get(source.pointee.metadata, cameraKey, nil, 0)?.pointee.value else { continue }
            try FFmpegError.check(av_dict_set(&context.pointee.metadata, key, value, 0))
        }
    }

    /// Copies the chapters that overlap the clip, cut to it and moved to clip time.
    func copyChapters(from source: UnsafeMutablePointer<AVFormatContext>, origin: RemuxTime, end: RemuxTime)
        throws(FFmpegError)
    {
        let chapters = (0..<Int(source.pointee.nb_chapters)).compactMap { source.pointee.chapters[$0] }
        let overlapping = chapters.filter { chapter in
            let timeBase = chapter.pointee.time_base
            return chapter.pointee.end > origin.value(in: timeBase) && chapter.pointee.start < end.value(in: timeBase)
        }
        guard !overlapping.isEmpty else { return }
        let slot = MemoryLayout<UnsafeMutablePointer<AVChapter>?>.stride
        guard let list = av_realloc_array(nil, overlapping.count, slot) else { throw .outOfMemory }
        context.pointee.chapters = list.assumingMemoryBound(to: UnsafeMutablePointer<AVChapter>?.self)
        for chapter in overlapping {
            guard let copy = av_mallocz(MemoryLayout<AVChapter>.size)?.assumingMemoryBound(to: AVChapter.self) else {
                throw .outOfMemory
            }
            context.pointee.chapters[Int(context.pointee.nb_chapters)] = copy
            context.pointee.nb_chapters += 1
            let timeBase = chapter.pointee.time_base
            let shift = origin.value(in: timeBase)
            copy.pointee.id = chapter.pointee.id
            copy.pointee.time_base = timeBase
            copy.pointee.start = max(chapter.pointee.start, shift) - shift
            copy.pointee.end = min(chapter.pointee.end, end.value(in: timeBase)) - shift
            try FFmpegError.check(av_dict_copy(&copy.pointee.metadata, chapter.pointee.metadata, 0))
        }
    }

    func writeHeader(options: [String: String]) throws(FFmpegError) {
        if let format, format.pointee.flags & AVFMT_NOFILE == 0 {
            try FFmpegError.check(avio_open(&context.pointee.pb, context.pointee.url, AVIO_FLAG_WRITE))
            isOpen = true
        }
        var dictionary: OpaquePointer?
        defer { av_dict_free(&dictionary) }
        for (key, value) in options {
            try FFmpegError.check(av_dict_set(&dictionary, key, value, 0))
        }
        try FFmpegError.check(avformat_write_header(context, &dictionary))
    }

    func timeBase(ofStream index: Int) -> AVRational {
        context.pointee.streams[index]?.pointee.time_base ?? RemuxTime.microseconds
    }

    func write(_ packet: Packet) throws(FFmpegError) {
        try FFmpegError.check(av_interleaved_write_frame(context, packet.pointer))
    }

    func finish() throws(FFmpegError) {
        try FFmpegError.check(av_write_trailer(context))
        guard isOpen else { return }
        isOpen = false
        try FFmpegError.check(avio_closep(&context.pointee.pb))
    }

    // MARK: Private

    private static let fileNameKey = "filename"
    private static let cameraKeys = [
        "com.apple.quicktime.location.ISO6709": "location",
        "com.apple.quicktime.make": "make",
        "com.apple.quicktime.model": "model",
        "com.apple.quicktime.title": "title",
        "com.apple.quicktime.description": "comment",
    ]

    // Keeps the source's codec tag (hvc1 vs hev1, DIVX vs XVID) unless the new container uses it for another codec.
    private func compatibleTag(for parameters: AVCodecParameters) -> UInt32 {
        guard let table = format?.pointee.codec_tag else { return parameters.codec_tag }
        var preferred: UInt32 = 0
        let sameCodec = av_codec_get_id(table, parameters.codec_tag) == parameters.codec_id
        let hasNoTag = av_codec_get_tag2(table, parameters.codec_id, &preferred) == 0
        return sameCodec || hasNoTag ? parameters.codec_tag : 0
    }
}
