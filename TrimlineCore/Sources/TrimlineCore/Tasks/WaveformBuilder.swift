import AVFoundation

actor WaveformBuilder {
    private let asset: AVURLAsset
    private let duration: TimeInterval
    private let cache: WaveformCache
    private let fileIdentity: WaveformCache.FileIdentity?
    private let queue = BlockingWork.queue(for: WaveformBuilder.self)

    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    // Small enough that the first chunk of a two-hour file arrives within a fraction of a second,
    // large enough to keep main actor updates rare.
    static let minimumChunkSize = 16

    private static var outputSettings: [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
    }

    init(asset: AVURLAsset, duration: TimeInterval, cache: WaveformCache, fileIdentity: WaveformCache.FileIdentity?) {
        self.asset = asset
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

    private func build(buckets: Int, into continuation: AsyncStream<PeakChunk>.Continuation) async {
        guard buckets > 0 else { return }
        if let fileIdentity, let cached = cache.peaks(for: fileIdentity, buckets: buckets) {
            continuation.yield(PeakChunk(firstBucket: 0, peaks: cached))
            return
        }
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
            let peaks = decode(track, buckets: buckets, into: continuation),
            !Task.isCancelled
        else { return }
        if let fileIdentity {
            cache.store(peaks, for: fileIdentity)
        }
    }

    // AVAssetReader is not Sendable, so the reader lives and dies inside this one call.
    private func decode(
        _ track: AVAssetTrack,
        buckets: Int,
        into continuation: AsyncStream<PeakChunk>.Continuation
    ) -> [Peak]? {
        guard let (reader, output) = startReading(track) else { return nil }
        var accumulator: PeakAccumulator?
        var samples: [Float] = []
        while let buffer = output.copyNextSampleBuffer() {
            guard !Task.isCancelled else {
                reader.cancelReading()
                return nil
            }
            guard let format = Self.streamFormat(of: buffer) else { continue }
            if accumulator == nil {
                let frames = Int((duration * format.mSampleRate).rounded())
                accumulator = PeakAccumulator(bucketCount: buckets, estimatedFrameCount: frames)
            }
            guard Self.copySamples(of: buffer, into: &samples) else { continue }
            samples.withUnsafeBufferPointer { accumulator?.add($0, channels: Int(format.mChannelsPerFrame)) }
            if let chunk = accumulator?.takeChunk(minimumSize: Self.minimumChunkSize) {
                continuation.yield(chunk)
            }
        }
        guard reader.status == .completed, var accumulator else { return nil }
        if let chunk = accumulator.finish() {
            continuation.yield(chunk)
        }
        return accumulator.completed
    }

    private func startReading(_ track: AVAssetTrack) -> (AVAssetReader, AVAssetReaderTrackOutput)? {
        guard let reader = try? AVAssetReader(asset: asset) else { return nil }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: Self.outputSettings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        return reader.startReading() ? (reader, output) : nil
    }

    private static func streamFormat(of buffer: CMSampleBuffer) -> AudioStreamBasicDescription? {
        guard let description = CMSampleBufferGetFormatDescription(buffer),
            let format = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
            format.mSampleRate > 0, format.mChannelsPerFrame > 0
        else { return nil }
        return format
    }

    // Copies into a reused array: the block buffer may be non-contiguous, and the copy is cheap next to decoding.
    private static func copySamples(of buffer: CMSampleBuffer, into samples: inout [Float]) -> Bool {
        guard let block = CMSampleBufferGetDataBuffer(buffer) else { return false }
        let byteCount = CMBlockBufferGetDataLength(block)
        let count = byteCount / MemoryLayout<Float>.size
        if samples.count != count {
            samples = [Float](repeating: 0, count: count)
        }
        let status = samples.withUnsafeMutableBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return kCMBlockBufferBadPointerParameterErr }
            return CMBlockBufferCopyDataBytes(
                block, atOffset: 0, dataLength: count * MemoryLayout<Float>.size, destination: base)
        }
        return status == kCMBlockBufferNoErr
    }
}
