import libavutil

final class Frame {
    let pointer: UnsafeMutablePointer<AVFrame>

    init() throws(FFmpegError) {
        guard let frame = av_frame_alloc() else { throw .outOfMemory }
        pointer = frame
    }

    deinit {
        var frame: UnsafeMutablePointer<AVFrame>? = pointer
        av_frame_free(&frame)
    }

    var bestEffortTimestamp: Int64 { pointer.pointee.best_effort_timestamp }
    var width: Int { Int(pointer.pointee.width) }
    var height: Int { Int(pointer.pointee.height) }
    var sampleCount: Int { Int(pointer.pointee.nb_samples) }

    func unref() {
        av_frame_unref(pointer)
    }
}
