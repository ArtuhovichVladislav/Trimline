import libavutil

enum FFmpegLog {
    // FFmpeg prints probe chatter for every unrecognised file; only real errors are worth stderr.
    static let quietOnce: Void = av_log_set_level(AV_LOG_ERROR)
}
