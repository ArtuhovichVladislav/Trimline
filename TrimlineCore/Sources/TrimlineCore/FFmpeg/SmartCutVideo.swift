import Foundation
import libavcodec
import libavformat

/// The picture of a smart cut, written as one stream: the re-encoded head, the source's packets from the
/// junction on, and the re-encoded outro before the end.
final class SmartCutVideo: TranscodedTrack {
    let inputIndex: Int
    var isFinished: Bool { head == nil && track.isFinished && (outro?.isFinished ?? true) }

    private let output: RemuxOutput
    private let cut: SmartCut
    private let window: RemuxWindow
    private var track: RemuxTrack
    private var head: VideoTranscode?
    private let headPackets: EncodedPackets?
    private let headShare: Double
    private let outro: VideoTranscode?
    private let outroPackets: EncodedPackets?
    private var feedsOutro = false
    // Copied packets wait until the head before them has been written.
    private var waiting: [Packet] = []

    // The decoder hands out the junction's own frame a few packets after it (frame threads, reordering);
    // a head that still hasn't ended by then is drained, so a damaged junction can't hold the whole clip.
    private static let maximumWaiting = 120

    init(stream: Demuxer.Stream, in demuxer: Demuxer, cut: SmartCut, output: RemuxOutput, window clip: RemuxWindow)
        throws(FFmpegError)
    {
        guard let source = demuxer.stream(stream.index) else { throw .invalidData }
        inputIndex = stream.index
        self.output = output
        self.cut = cut
        let timeBase = stream.timeBase
        let outputIndex = try output.addStream(copying: source)
        track = RemuxTrack(
            inputIndex: stream.index, outputIndex: outputIndex, role: .video, inputTimeBase: timeBase,
            outputTimeBase: timeBase)
        let junction = RemuxTime(value: cut.junction, timeBase: timeBase)
        window = RemuxWindow(
            origin: clip.origin, firstPrimary: junction, end: clip.end, hidesPreroll: false,
            primaryIndex: stream.index)
        let length = max(clip.end.seconds - clip.origin.seconds, .leastNonzeroMagnitude)
        headShare = min(1, max(0, (junction.seconds - clip.origin.seconds) / length))
        if let encoder = cut.headEncoder {
            let packets = EncodedPackets(encoder: encoder)
            headPackets = packets
            head = try VideoTranscode(
                stream: stream, output: packets,
                span: TranscodeSpan(origin: clip.origin.seconds, end: junction.seconds), reportsProgress: true)
        } else {
            headPackets = nil
        }
        if let plan = cut.outro {
            let packets = EncodedPackets(encoder: plan.encoder)
            outroPackets = packets
            let start = RemuxTime(value: plan.start, timeBase: timeBase).seconds
            outro = try VideoTranscode(
                stream: stream, output: packets, span: TranscodeSpan(origin: start, end: clip.end.seconds),
                reportsProgress: false)
        } else {
            outroPackets = nil
            outro = nil
        }
    }

    func process(_ packet: Packet, isCancelled: Remuxer.Cancellation, progress: Remuxer.Progress) throws(FFmpegError) {
        if let head {
            let share = headShare
            try head.process(packet, isCancelled: isCancelled, progress: { progress($0 * share) })
            try writeEncoded(headPackets, from: window.origin.value(in: track.inputTimeBase))
            if head.isFinished || waiting.count > Self.maximumWaiting {
                try finishHead(progress: progress)
            }
        }
        if let outro, let plan = cut.outro, !outro.isFinished {
            feedsOutro = feedsOutro || (packet.isKeyframe && packet.pts == plan.decodeFrom)
            if feedsOutro {
                try outro.process(packet, isCancelled: isCancelled, progress: { _ in })
            }
        }
        try copy(packet, progress: progress)
    }

    func finish(progress: Remuxer.Progress) throws(FFmpegError) {
        try finishHead(progress: progress)
        guard let outro, let plan = cut.outro else { return }
        try outro.finish(progress: { _ in })
        try writeEncoded(outroPackets, from: plan.start)
    }

    // MARK: Private

    private func finishHead(progress: Remuxer.Progress) throws(FFmpegError) {
        guard let head else { return }
        let share = headShare
        try head.finish(progress: { progress($0 * share) })
        try writeEncoded(headPackets, from: window.origin.value(in: track.inputTimeBase))
        self.head = nil
        for packet in waiting {
            try write(packet, progress: progress)
        }
        waiting.removeAll()
    }

    /// The encoder stamps time from the start of its part in the source's time base; the copy is retimed
    /// from source time, so encoded packets are moved back there first.
    private func writeEncoded(_ packets: EncodedPackets?, from start: Int64) throws(FFmpegError) {
        guard let packets else { return }
        for packet in packets.take() {
            packet.pointer.pointee.pts = try FFmpegTime.sum(packet.pts, start)
            packet.pointer.pointee.dts = try FFmpegTime.difference(packet.pts, cut.delay)
            try cut.bitstream.convertEncoded(packet)
            try write(packet, progress: { _ in })
        }
    }

    private func copy(_ packet: Packet, progress: Remuxer.Progress) throws(FFmpegError) {
        guard !track.isFinished else { return }
        if track.hasStarted, let stop = cut.stop, packet.pts == stop {
            track.isFinished = true
            return
        }
        // Leading pictures follow the junction but are shown before it: the head has them already.
        if track.hasStarted, packet.pts != FFmpegTime.noValue, packet.pts < cut.junction { return }
        let isJunction = !track.hasStarted
        guard window.decide(packet, track: &track) == .write else { return }
        let copy = try Packet()
        try FFmpegError.check(av_packet_ref(copy.pointer, packet.pointer))
        if isJunction, cut.headEncoder != nil {
            try cut.bitstream.rewriteJunction(copy)
        } else if copy.isKeyframe, cut.reencodes {
            try cut.bitstream.addParameterSets(to: copy)
        }
        if head != nil {
            waiting.append(copy)
        } else {
            try write(copy, progress: progress)
        }
    }

    private func write(_ packet: Packet, progress: Remuxer.Progress) throws(FFmpegError) {
        if let shown = FFmpegTime.seconds(packet.pts, in: track.inputTimeBase) {
            let span = max(window.end.seconds - window.origin.seconds, .leastNonzeroMagnitude)
            progress((shown - window.origin.seconds) / span)
        }
        // The muxer may pick its own time base when it writes the header, after this track was set up.
        track.outputTimeBase = output.timeBase(ofStream: track.outputIndex)
        try track.retime(packet, window: window, allowsEqualDts: output.allowsEqualDts)
        try output.write(packet)
    }
}

/// Collects an encoder's packets for the smart cut to stamp and write in order.
private final class EncodedPackets: EncodedVideoOutput {
    let encoder: Encoder
    private var packets: [Packet] = []

    init(encoder: Encoder) {
        self.encoder = encoder
    }

    func send(_ frame: Frame?) throws(FFmpegError) {
        try encoder.send(frame)
        while true {
            let packet = try Packet()
            guard try encoder.receive(into: packet) else { return }
            packets.append(packet)
        }
    }

    func take() -> [Packet] {
        defer { packets.removeAll() }
        return packets
    }
}
