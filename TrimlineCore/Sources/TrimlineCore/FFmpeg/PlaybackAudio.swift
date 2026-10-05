import AudioToolbox
import CoreMedia

/// Decodes audio to interleaved Float32 at the source rate for AVSampleBufferAudioRenderer.
final class AudioSource: PlaybackSource {
    private static let maximumChannels = 2
    // Container timestamps are often rounded to milliseconds; following them exactly would leave
    // tiny gaps the renderer plays as clicks, so only real jumps reset the running clock.
    private static let resyncThreshold: TimeInterval = 0.1

    private let decoder: Decoder
    private let resampler: Resampler
    private let frame: Frame
    private let format: CMAudioFormatDescription
    private let timing: StreamTiming
    private let sampleRate: Int32
    private let channels: Int
    private var samples: [Float] = []
    private var start = CMTime.zero
    private var nextTime: CMTime?

    init(stream: Demuxer.Stream, timing: StreamTiming) throws(FFmpegError) {
        guard stream.sampleRate > 0 else { throw .invalidData }
        decoder = try Decoder(stream: stream)
        frame = try Frame()
        sampleRate = Int32(stream.sampleRate)
        channels = min(max(stream.channelCount, 1), Self.maximumChannels)
        resampler = Resampler(outputSampleRate: stream.sampleRate, outputChannels: channels)
        guard let format = Self.makeFormat(sampleRate: Double(stream.sampleRate), channels: channels) else {
            throw .invalidData
        }
        self.format = format
        self.timing = timing
    }

    func restart(at start: CMTime) {
        decoder.flush()
        self.start = start
        nextTime = nil
    }

    func append(_ packet: Packet, to output: inout [CMSampleBuffer]) {
        try? decoder.send(packet)
        receiveFrames(to: &output)
    }

    func drain(to output: inout [CMSampleBuffer]) {
        try? decoder.send(nil)
        receiveFrames(to: &output)
    }

    private func receiveFrames(to output: inout [CMSampleBuffer]) {
        while (try? decoder.receive(into: frame)) == true {
            samples.removeAll(keepingCapacity: true)
            guard (try? resampler.convert(frame, appendingTo: &samples)) != nil, !samples.isEmpty else { continue }
            if let sample = makeSample(at: presentationTime()) {
                output.append(sample)
            }
        }
    }

    private func presentationTime() -> CMTime {
        let stamped = timing.time(frame.bestEffortTimestamp)
        guard let nextTime else { return stamped ?? start }
        guard let stamped, abs((stamped - nextTime).seconds) > Self.resyncThreshold else { return nextTime }
        return stamped
    }

    private func makeSample(at time: CMTime) -> CMSampleBuffer? {
        let frameCount = samples.count / channels
        nextTime = time + CMTime(value: Int64(frameCount), timescale: sampleRate)
        let late = (start - time).seconds * Double(sampleRate)
        let skipped = Int(max(0, FFmpegTime.rounded(late) ?? (late > 0 ? .max : 0)))
        guard skipped < frameCount else { return nil }
        let presentation = time + CMTime(value: Int64(skipped), timescale: sampleRate)

        let block = samples[(skipped * channels)...].withUnsafeBytes { PlaybackBuffers.blockBuffer(copying: $0) }
        guard let block else { return nil }
        var sample: CMSampleBuffer?
        let status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: frameCount - skipped,
            presentationTimeStamp: presentation, packetDescriptions: nil, sampleBufferOut: &sample)
        return status == noErr ? sample : nil
    }

    private static func makeFormat(sampleRate: Double, channels: Int) -> CMAudioFormatDescription? {
        let bytesPerFrame = UInt32(MemoryLayout<Float>.size * channels)
        var description = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: bytesPerFrame, mFramesPerPacket: 1, mBytesPerFrame: bytesPerFrame,
            mChannelsPerFrame: UInt32(channels), mBitsPerChannel: UInt32(MemoryLayout<Float>.size * UInt8.bitWidth),
            mReserved: 0)
        var format: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(
            allocator: nil, asbd: &description, layoutSize: 0, layout: nil, magicCookieSize: 0,
            magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
        return status == noErr ? format : nil
    }
}
