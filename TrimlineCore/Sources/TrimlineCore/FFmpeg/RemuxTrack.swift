import libavcodec
import libavformat
import libavutil

/// A moment expressed exactly in some stream's time base.
struct RemuxTime {
    static let microseconds = AVRational(num: 1, den: Int32(FFmpegTime.microsecondsPerSecond))

    let value: Int64
    let timeBase: AVRational

    init(value: Int64, timeBase: AVRational) {
        self.value = value
        self.timeBase = timeBase
    }

    init(seconds: Double) {
        self.init(value: FFmpegTime.timestamp(seconds, in: Self.microseconds), timeBase: Self.microseconds)
    }

    func value(in other: AVRational) -> Int64 {
        av_rescale_q(value, timeBase, other)
    }

    var seconds: Double { FFmpegTime.seconds(value, in: timeBase) ?? 0 }
}

/// One copied stream: where its packets go and what is already known about them.
struct RemuxTrack {
    enum Role {
        case video
        case audio
        case subtitle
        case picture
        case attachment
    }

    let inputIndex: Int
    let outputIndex: Int
    let role: Role
    let inputTimeBase: AVRational
    var outputTimeBase: AVRational
    var hasStarted = false
    var isFinished = false
    var lastDts = FFmpegTime.noValue
    var nextInputDts = FFmpegTime.noValue

    var isTimed: Bool { role == .video || role == .audio }
}

/// The part of the source that ends up in the clip, in the source's timestamps.
struct RemuxWindow {
    /// Clip time 0. With an edit list this is the requested start; elsewhere the first copied frame.
    let origin: RemuxTime
    /// The first packet of the primary stream: the key frame at or before the start, or the audio
    /// packet holding it.
    let firstPrimary: RemuxTime
    let end: RemuxTime
    /// Edit-list containers hide what comes before the origin, so streams may start a little earlier;
    /// audio keeps a preroll for the decoder to warm up before the first frame that is heard.
    let hidesPreroll: Bool
    let primaryIndex: Int

    static let audioPreroll = RemuxTime(seconds: 0.1)

    enum Decision {
        case drop
        case write
        /// Shown after the end, but frames before the end may still refer to it.
        case hold
    }

    func decide(_ packet: Packet, track: inout RemuxTrack) -> Decision {
        let pointer = packet.pointer.pointee
        let time = packet.time
        switch track.role {
        case .attachment:
            return .drop
        case .picture:
            guard !track.hasStarted else { return .drop }
            track.hasStarted = true
            track.isFinished = true
            return .write
        case .video, .audio, .subtitle:
            guard time != FFmpegTime.noValue else { return track.hasStarted && !track.isFinished ? .write : .drop }
            let decodeTime = pointer.dts != FFmpegTime.noValue && track.role == .video ? pointer.dts : time
            if decodeTime >= end.value(in: track.inputTimeBase) {
                track.isFinished = true
                return .drop
            }
            guard track.hasStarted || starts(packet, at: time, track: track) else { return .drop }
            track.hasStarted = true
            return track.role == .video && time >= end.value(in: track.inputTimeBase) ? .hold : .write
        }
    }

    private func starts(_ packet: Packet, at time: Int64, track: RemuxTrack) -> Bool {
        let timeBase = track.inputTimeBase
        if track.inputIndex == primaryIndex {
            return time >= firstPrimary.value(in: timeBase) && (track.role != .video || packet.isKeyframe)
        }
        let originTime = origin.value(in: timeBase)
        let endTime = time.addingReportingOverflow(max(0, packet.duration))
        switch track.role {
        case .video:
            return packet.isKeyframe && (hidesPreroll || time >= originTime)
        case .audio:
            guard hidesPreroll else { return time >= originTime }
            let prerollStart = originTime.subtractingReportingOverflow(Self.audioPreroll.value(in: timeBase))
            return endTime.overflow || prerollStart.overflow || endTime.partialValue > prerollStart.partialValue
        default:
            return endTime.overflow || endTime.partialValue > originTime || time >= originTime
        }
    }
}

extension RemuxTrack {
    /// Moves the packet to clip time and the output time base, keeping decode times increasing.
    mutating func retime(_ packet: Packet, window: RemuxWindow, allowsEqualDts: Bool) throws(FFmpegError) {
        let pointer = packet.pointer
        pointer.pointee.stream_index = Int32(outputIndex)
        pointer.pointee.pos = -1
        if role == .picture {
            pointer.pointee.pts = 0
            pointer.pointee.dts = 0
            return
        }
        fillMissingTimes(pointer)
        let shift = window.origin.value(in: inputTimeBase)
        if role == .subtitle {
            try cutSubtitle(pointer, from: shift, to: window.end.value(in: inputTimeBase))
        }
        if pointer.pointee.pts != FFmpegTime.noValue {
            pointer.pointee.pts = try FFmpegTime.difference(pointer.pointee.pts, shift)
        }
        if pointer.pointee.dts != FFmpegTime.noValue {
            pointer.pointee.dts = try FFmpegTime.difference(pointer.pointee.dts, shift)
        }
        av_packet_rescale_ts(pointer, inputTimeBase, outputTimeBase)
        try keepDtsIncreasing(pointer, allowsEqual: allowsEqualDts)
    }

    // MPEG program streams stamp only some packets; the others follow the previous one.
    private mutating func fillMissingTimes(_ pointer: UnsafeMutablePointer<AVPacket>) {
        if pointer.pointee.dts == FFmpegTime.noValue {
            pointer.pointee.dts = nextInputDts
        }
        if pointer.pointee.pts == FFmpegTime.noValue, role != .video {
            pointer.pointee.pts = pointer.pointee.dts
        }
        let dts = pointer.pointee.dts
        nextInputDts =
            dts == FFmpegTime.noValue || pointer.pointee.duration <= 0
            ? FFmpegTime.noValue : (try? FFmpegTime.sum(dts, pointer.pointee.duration)) ?? FFmpegTime.noValue
    }

    private func cutSubtitle(_ pointer: UnsafeMutablePointer<AVPacket>, from start: Int64, to end: Int64)
        throws(FFmpegError)
    {
        let pts = pointer.pointee.pts
        guard pts != FFmpegTime.noValue else { return }
        if pointer.pointee.duration > 0, try FFmpegTime.sum(pts, pointer.pointee.duration) > end {
            pointer.pointee.duration = max(0, try FFmpegTime.difference(end, pts))
        }
        guard pts < start else { return }
        let late = try FFmpegTime.difference(start, pts)
        pointer.pointee.duration = max(0, try FFmpegTime.difference(pointer.pointee.duration, late))
        pointer.pointee.pts = start
        pointer.pointee.dts = start
    }

    private mutating func keepDtsIncreasing(_ pointer: UnsafeMutablePointer<AVPacket>, allowsEqual: Bool)
        throws(FFmpegError)
    {
        let dts = pointer.pointee.dts
        guard dts != FFmpegTime.noValue else { return }
        if lastDts != FFmpegTime.noValue {
            let minimum = try FFmpegTime.sum(lastDts, allowsEqual ? 0 : 1)
            if dts < minimum {
                pointer.pointee.dts = minimum
                if pointer.pointee.pts != FFmpegTime.noValue {
                    pointer.pointee.pts = max(pointer.pointee.pts, minimum)
                }
            }
        }
        lastDts = pointer.pointee.dts
    }
}
