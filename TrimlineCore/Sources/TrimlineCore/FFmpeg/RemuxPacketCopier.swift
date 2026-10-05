import Foundation
import libavcodec

/// The copy loop: reads the source from the seek point and writes what belongs to the clip.
struct RemuxPacketCopier {
    let demuxer: Demuxer
    let output: RemuxOutput
    let window: RemuxWindow
    var tracks: [RemuxTrack]
    var streamInfo: FLACStreamInfo?
    var frameNumbers: FLACFrameNumbers?
    var blockNumbers: WavPackBlockNumbers?
    private var held: [[Packet]]
    private let positions: [Int: Int]

    // Interleaving in real files drifts by a second or two; past this nothing of the clip can follow.
    private static let endSlack: TimeInterval = 10
    // Far more than any B-frame pyramid; frames held longer than this can't be references for the clip.
    private static let maximumHeldPackets = 32

    init(demuxer: Demuxer, output: RemuxOutput, window: RemuxWindow, tracks: [RemuxTrack]) {
        self.demuxer = demuxer
        self.output = output
        self.window = window
        self.tracks = tracks
        held = Array(repeating: [], count: tracks.count)
        positions = Dictionary(uniqueKeysWithValues: tracks.enumerated().map { ($1.inputIndex, $0) })
    }

    mutating func run(isCancelled: Remuxer.Cancellation, progress: Remuxer.Progress) throws(FFmpegError) {
        let packet = try Packet()
        while try demuxer.read(into: packet) {
            guard !isCancelled() else { throw RemuxStop.cancelled }
            guard let position = position(ofInput: packet.streamIndex) else { continue }
            if try copy(packet, position: position, progress: progress) == .drop, isFinished || isPastEnd(packet) {
                return
            }
        }
    }

    var isFinished: Bool { tracks.allSatisfy { !$0.isTimed || $0.isFinished } }

    func position(ofInput index: Int) -> Int? { positions[index] }

    /// Past this nothing of the clip can follow.
    func isPastEnd(_ packet: Packet) -> Bool {
        guard let stream = demuxer.stream(packet.streamIndex),
            let time = FFmpegTime.seconds(packet.dts, in: stream.pointee.time_base)
        else { return false }
        return time > window.end.seconds + Self.endSlack
    }

    @discardableResult
    mutating func copy(_ packet: Packet, position: Int, progress: Remuxer.Progress) throws(FFmpegError)
        -> RemuxWindow.Decision
    {
        let decision = window.decide(packet, track: &tracks[position])
        switch decision {
        case .drop:
            if tracks[position].isFinished { held[position].removeAll() }
        case .hold:
            try hold(packet, position: position)
        case .write:
            if packet.streamIndex == window.primaryIndex, let shown = presentationTime(packet, position: position) {
                let span = max(window.end.seconds - window.origin.seconds, .leastNonzeroMagnitude)
                progress((shown - window.origin.seconds) / span)
            }
            for earlier in held[position] {
                try write(earlier, position: position)
            }
            held[position].removeAll()
            try write(packet, position: position)
        }
        return decision
    }

    // MARK: Private

    private mutating func hold(_ packet: Packet, position: Int) throws(FFmpegError) {
        guard held[position].count < Self.maximumHeldPackets else {
            held[position].removeAll()
            return
        }
        let copy = try Packet()
        av_packet_move_ref(copy.pointer, packet.pointer)
        held[position].append(copy)
    }

    private mutating func write(_ packet: Packet, position: Int) throws(FFmpegError) {
        if packet.streamIndex == window.primaryIndex {
            try streamInfo?.attach(to: packet, timeBase: tracks[position].inputTimeBase)
            try frameNumbers?.renumber(packet)
            try blockNumbers?.renumber(packet)
        }
        try tracks[position].retime(packet, window: window, allowsEqualDts: output.allowsEqualDts)
        try output.write(packet)
    }

    private func presentationTime(_ packet: Packet, position: Int) -> TimeInterval? {
        let timeBase = tracks[position].inputTimeBase
        return FFmpegTime.seconds(packet.pts, in: timeBase) ?? FFmpegTime.seconds(packet.dts, in: timeBase)
    }
}
