import Foundation

actor FFmpegWaveformBuilder {
    private let url: URL
    private let streamIndex: Int?
    private let duration: TimeInterval
    private let cache: WaveformCache
    private let fileIdentity: WaveformCache.FileIdentity?
    private let queue = BlockingWork.queue(for: FFmpegWaveformBuilder.self)

    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    // A few thousand buckets over the whole file need nowhere near the source rate, and a low rate keeps
    // resampling and folding cheap next to decoding.
    private static let analysisSampleRate = 11_025
    private static let maximumChannels = 2

    init(
        url: URL,
        streamIndex: Int?,
        duration: TimeInterval,
        cache: WaveformCache,
        fileIdentity: WaveformCache.FileIdentity?
    ) {
        self.url = url
        self.streamIndex = streamIndex
        self.duration = duration
        self.cache = cache
        self.fileIdentity = fileIdentity
    }

    nonisolated func peaks(buckets: Int) -> AsyncStream<PeakChunk> {
        AsyncStream { continuation in
            let task = Task {
                await self.build(buckets: buckets, into: continuation)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Private

    private func build(buckets: Int, into continuation: AsyncStream<PeakChunk>.Continuation) {
        guard buckets > 0, let streamIndex else { return }
        if let fileIdentity, let cached = cache.peaks(for: fileIdentity, buckets: buckets) {
            continuation.yield(PeakChunk(firstBucket: 0, peaks: cached))
            return
        }
        guard let peaks = try? decode(streamIndex, buckets: buckets, into: continuation), !Task.isCancelled
        else { return }
        if let fileIdentity {
            cache.store(peaks, for: fileIdentity)
        }
    }

    private func decode(
        _ streamIndex: Int,
        buckets: Int,
        into continuation: AsyncStream<PeakChunk>.Continuation
    ) throws(FFmpegError) -> [Peak]? {
        let demuxer = try Demuxer(url: url)
        guard let stream = demuxer.streams.first(where: { $0.index == streamIndex }) else { return nil }
        demuxer.discardAllStreams(except: streamIndex)
        let decoder = try Decoder(stream: stream)
        let resampler = Resampler(
            outputSampleRate: Self.analysisSampleRate,
            outputChannels: min(max(1, stream.channelCount), Self.maximumChannels)
        )
        let frames = Int(FFmpegTime.rounded(duration * Double(Self.analysisSampleRate)) ?? 0)
        var folder = SampleFolder(
            decoder: decoder,
            resampler: resampler,
            accumulator: PeakAccumulator(bucketCount: buckets, estimatedFrameCount: frames),
            frame: try Frame()
        )
        let packet = try Packet()
        while try demuxer.read(into: packet) {
            guard !Task.isCancelled else { return nil }
            guard packet.streamIndex == streamIndex else { continue }
            folder.fold(packet)
            if let chunk = folder.accumulator.takeChunk(minimumSize: WaveformBuilder.minimumChunkSize) {
                continuation.yield(chunk)
            }
        }
        folder.fold(nil)
        if let chunk = folder.accumulator.finish() {
            continuation.yield(chunk)
        }
        return folder.accumulator.completed
    }
}

private struct SampleFolder {
    let decoder: Decoder
    let resampler: Resampler
    var accumulator: PeakAccumulator
    let frame: Frame
    private var samples: [Float] = []

    init(decoder: Decoder, resampler: Resampler, accumulator: PeakAccumulator, frame: Frame) {
        self.decoder = decoder
        self.resampler = resampler
        self.accumulator = accumulator
        self.frame = frame
    }

    /// `nil` drains the decoder at the end of the stream.
    mutating func fold(_ packet: Packet?) {
        // A damaged packet costs a gap in the waveform, not the whole waveform.
        try? decoder.send(packet)
        while (try? decoder.receive(into: frame)) == true {
            samples.removeAll(keepingCapacity: true)
            guard (try? resampler.convert(frame, appendingTo: &samples)) != nil else { continue }
            samples.withUnsafeBufferPointer { accumulator.add($0, channels: resampler.outputChannels) }
        }
    }
}
