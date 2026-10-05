import Foundation
import libavcodec
import libavformat

/// Writes a clip whose streams can't all be copied: precise mode re-encodes the picture, and either mode
/// re-encodes what the container can't hold (RealMedia, Monkey's Audio). Everything else is copied packet
/// by packet; a clip with nothing to encode goes to the Remuxer. Blocking, like the Remuxer.
struct Transcoder {
    let source: URL
    let container: ExportContainer
    let mode: ExportMode

    // Audio decoders need a frame or two before the cut to produce its first samples.
    private static let audioDecoderPreroll: TimeInterval = 0.1
    // Every copied stream follows the window's own rules when the picture is re-encoded.
    private static let noPrimary = -1

    func export(
        _ range: ClosedRange<TimeInterval>, to destination: URL, isCancelled: Remuxer.Cancellation,
        progress: Remuxer.Progress
    ) throws(RemuxError) -> [SkippedStream] {
        let demuxer = try Self.open(source)
        let plan = TranscodePlan(demuxer: demuxer, container: container, mode: mode)
        guard plan.encodes else {
            return try Remuxer(source: source, container: container)
                .remux(range, to: destination, isCancelled: isCancelled, progress: progress)
        }
        do throws(FFmpegError) {
            let output = try RemuxOutput(path: destination.path, muxer: container.muxer)
            var session = try prepare(demuxer, plan: plan, range: range, output: output, isCancelled: isCancelled)
            try session.run(isCancelled: isCancelled, progress: progress)
            try output.finish()
            return plan.skipped
        } catch {
            throw Remuxer.remuxError(error)
        }
    }

    /// The codec the picture is encoded to in `container`, or `nil` when it is copied or there is none.
    static func videoEncoding(of source: URL, container: ExportContainer, mode: ExportMode) -> String? {
        guard let demuxer = try? open(source) else { return nil }
        return TranscodePlan(demuxer: demuxer, container: container, mode: mode).videoEncoding?.codecName
    }

    /// Whether precise saving of `range` copies the picture after the first key frame instead of encoding
    /// all of it. Reads the file around both ends of the range.
    func cutsSmartly(_ range: ClosedRange<TimeInterval>) -> Bool {
        guard mode == .precise, let demuxer = try? Self.open(source) else { return false }
        let plan = TranscodePlan(demuxer: demuxer, container: container, mode: mode)
        guard let primary = plan.primary,
            let start = try? cut(demuxer, at: range, primary: primary, isCancelled: { false }).0
        else { return false }
        return (try? smartCut(demuxer, at: range, primary: primary, start: start, isCancelled: { false })) != nil
    }

    // MARK: Private

    private static func open(_ source: URL) throws(RemuxError) -> Demuxer {
        do {
            let demuxer = try Demuxer(url: source)
            demuxer.context.pointee.flags |= AVFMT_FLAG_GENPTS
            return demuxer
        } catch {
            throw .unreadable
        }
    }

    private func prepare(
        _ demuxer: Demuxer, plan: TranscodePlan, range: ClosedRange<TimeInterval>, output: RemuxOutput,
        isCancelled: Remuxer.Cancellation
    ) throws(FFmpegError) -> TranscodeSession {
        guard plan.keepsMainContent(of: demuxer, content: container.content), let primary = plan.primary else {
            throw RemuxStop.noStreams
        }
        let (start, window) = try cut(demuxer, at: range, primary: primary, isCancelled: isCancelled)
        let smartCut = try smartCut(demuxer, at: range, primary: primary, start: start, isCancelled: isCancelled)
        let (copied, encoded) = try addStreams(
            plan, from: demuxer, to: output, window: window, primaryIndex: primary.index, smartCut: smartCut)
        var tracks = copied
        try output.copyMetadata(from: demuxer.context, mapsCameraKeys: container.hasEditList)
        try output.copyChapters(from: demuxer.context, origin: window.origin, end: window.end)
        try output.writeHeader(options: container.muxerOptions)
        for index in tracks.indices {
            tracks[index].outputTimeBase = output.timeBase(ofStream: tracks[index].outputIndex)
        }
        let reader = try demuxer.positioned(at: start.seek, streamIndex: primary.index)
        let copier = RemuxPacketCopier(demuxer: reader, output: output, window: window, tracks: tracks)
        return TranscodeSession(demuxer: reader, copier: copier, encoded: encoded)
    }

    /// Where reading starts and which part of the source becomes the clip. Re-encoded clips start exactly
    /// at the request; a copied picture starts on its key frame, so everything else starts there too.
    private func cut(
        _ demuxer: Demuxer, at range: ClosedRange<TimeInterval>, primary: TranscodePlan.Entry,
        isCancelled: Remuxer.Cancellation
    ) throws(FFmpegError) -> (RemuxStart, RemuxWindow) {
        guard let stream = demuxer.stream(primary.index) else { throw RemuxStop.noStreams }
        let base = demuxer.timelineOrigin
        let timeBase = stream.pointee.time_base
        let track = RemuxTrack(
            inputIndex: primary.index, outputIndex: -1, role: primary.role, inputTimeBase: timeBase,
            outputTimeBase: timeBase)
        let preroll = primary.role == .audio ? Self.audioDecoderPreroll : 0
        let start = try RemuxStart.locate(
            in: demuxer, track: track, at: base + range.lowerBound - preroll, isCancelled: isCancelled)
        let copiesPicture = primary.role == .video && primary.action == .copy
        let first = RemuxTime(value: start.firstTime, timeBase: timeBase)
        let startsOnKeyframe = copiesPicture && !start.startsLater
        let window = RemuxWindow(
            origin: startsOnKeyframe ? first : RemuxTime(seconds: base + range.lowerBound), firstPrimary: first,
            end: RemuxTime(seconds: base + range.upperBound), hidesPreroll: false,
            primaryIndex: copiesPicture ? primary.index : Self.noPrimary)
        return (start, window)
    }

    /// Precise video of a codec the hardware encoder writes is encoded only up to the next clean key frame.
    private func smartCut(
        _ demuxer: Demuxer, at range: ClosedRange<TimeInterval>, primary: TranscodePlan.Entry, start: RemuxStart,
        isCancelled: Remuxer.Cancellation
    ) throws(FFmpegError) -> SmartCut? {
        guard mode == .precise, primary.role == .video, case .encode = primary.action,
            let stream = demuxer.streams.first(where: { $0.index == primary.index })
        else { return nil }
        let base = demuxer.timelineOrigin
        return try SmartCut.locate(
            in: demuxer, stream: stream, container: container, start: start,
            range: (base + range.lowerBound)...(base + range.upperBound), isCancelled: isCancelled)
    }

    private func addStreams(
        _ plan: TranscodePlan, from demuxer: Demuxer, to output: RemuxOutput, window: RemuxWindow, primaryIndex: Int,
        smartCut: SmartCut?
    ) throws(FFmpegError) -> ([RemuxTrack], [any TranscodedTrack]) {
        let span = TranscodeSpan(origin: window.origin.seconds, end: window.end.seconds)
        var tracks: [RemuxTrack] = []
        var encoded: [any TranscodedTrack] = []
        for entry in plan.entries {
            guard let stream = demuxer.stream(entry.index) else { continue }
            switch entry.action {
            case .skip:
                stream.pointee.discard = AVDISCARD_ALL
            case .copy:
                let becomesAttachment = entry.role == .picture && container.rules.attachments
                let outputIndex =
                    becomesAttachment
                    ? try output.addAttachment(picture: stream) : try output.addStream(copying: stream)
                tracks.append(
                    RemuxTrack(
                        inputIndex: entry.index, outputIndex: outputIndex,
                        role: becomesAttachment ? .attachment : entry.role,
                        inputTimeBase: stream.pointee.time_base, outputTimeBase: stream.pointee.time_base))
            case .encode(let encoding):
                guard let described = demuxer.streams.first(where: { $0.index == entry.index }) else { continue }
                let reports = entry.index == primaryIndex
                if reports, let smartCut {
                    encoded.append(
                        try SmartCutVideo(stream: described, in: demuxer, cut: smartCut, output: output, window: window)
                    )
                    continue
                }
                let track: any TranscodedTrack =
                    entry.role == .video
                    ? try VideoTranscode(
                        stream: described, in: demuxer, encoding: encoding, output: output, span: span,
                        reportsProgress: reports)
                    : try AudioTranscode(
                        stream: described, in: demuxer, encoding: encoding, output: output, span: span,
                        reportsProgress: reports)
                encoded.append(track)
            }
        }
        return (tracks, encoded)
    }
}

/// A track of the clip that is decoded and encoded again instead of copied.
protocol TranscodedTrack: AnyObject {
    var inputIndex: Int { get }
    var isFinished: Bool { get }
    func process(_ packet: Packet, isCancelled: Remuxer.Cancellation, progress: Remuxer.Progress) throws(FFmpegError)
    /// Drains the decoder and the encoder at the end of the clip.
    func finish(progress: Remuxer.Progress) throws(FFmpegError)
}

/// The part of the source a re-encoded track keeps, in source seconds; clip time 0 is `origin`.
struct TranscodeSpan {
    let origin: TimeInterval
    let end: TimeInterval

    var length: TimeInterval { max(end - origin, .leastNonzeroMagnitude) }
}

/// The read loop: every packet goes to its decoder or straight to the copier.
struct TranscodeSession {
    let demuxer: Demuxer
    var copier: RemuxPacketCopier
    let encoded: [any TranscodedTrack]

    mutating func run(isCancelled: Remuxer.Cancellation, progress: Remuxer.Progress) throws(FFmpegError) {
        let packet = try Packet()
        let byInput = Dictionary(uniqueKeysWithValues: encoded.map { ($0.inputIndex, $0) })
        while try demuxer.read(into: packet) {
            guard !isCancelled() else { throw RemuxStop.cancelled }
            let isPastEnd = copier.isPastEnd(packet)
            if let track = byInput[packet.streamIndex] {
                try track.process(packet, isCancelled: isCancelled, progress: progress)
            } else if let position = copier.position(ofInput: packet.streamIndex) {
                try copier.copy(packet, position: position, progress: progress)
            } else {
                continue
            }
            if isPastEnd || (copier.isFinished && encoded.allSatisfy(\.isFinished)) { break }
        }
        for track in encoded {
            guard !isCancelled() else { throw RemuxStop.cancelled }
            try track.finish(progress: progress)
        }
    }
}

extension TranscodePlan {
    /// The stream the cut is placed on: the picture, or the sound when there is none.
    var primary: Entry? {
        let kept = entries.filter { if case .skip = $0.action { false } else { true } }
        return kept.first { $0.role == .video } ?? kept.first { $0.role == .audio }
    }

    func keepsMainContent(of demuxer: Demuxer, content: ExportContent) -> Bool {
        let kept = Set(entries.filter { if case .skip = $0.action { false } else { true } }.map(\.role))
        return Remuxer.keepsMainContent(kept, of: demuxer, content: content)
    }
}
