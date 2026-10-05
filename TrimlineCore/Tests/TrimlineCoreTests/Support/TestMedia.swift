import AVFoundation
import CoreVideo
import Foundation

enum TestMedia {
    struct VideoSpec: Hashable {
        var duration: TimeInterval = 4
        var frameRate: Int32 = 30
        var keyframeInterval: Int = 30
        var width = 320
        var height = 180
        var withAudio = true
        var fileType: AVFileType = .mov
    }

    struct AudioSpec: Hashable {
        var duration: TimeInterval = 3
        var sampleRate: Double = 44_100
        var fileType: AVFileType = .wav
    }

    static func makeTemporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("TrimlineTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    static func video(_ spec: VideoSpec = VideoSpec()) async throws -> URL {
        let ext = spec.fileType == .mp4 ? "mp4" : "mov"
        let url = sharedFolder.appendingPathComponent("video-\(spec.hashValue).\(ext)")
        return try await fixtures.file(at: url) { try await writeVideo(spec, to: url) }
    }

    private static func writeVideo(_ spec: VideoSpec, to url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: spec.fileType)
        let video = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: spec.width,
                AVVideoHeightKey: spec.height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoMaxKeyFrameIntervalKey: spec.keyframeInterval,
                    AVVideoAllowFrameReorderingKey: false,
                ],
            ]
        )
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: video,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: spec.width,
                kCVPixelBufferHeightKey as String: spec.height,
            ]
        )
        writer.add(video)
        let audio = spec.withAudio ? makeAACInput() : nil
        if let audio { writer.add(audio) }

        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        // Tracks are written in step: AVAssetWriter interleaves them and stops accepting video
        // while it waits for audio of the same time.
        var tone = audio.map { SineWriter(input: $0, totalDuration: spec.duration, sampleRate: 44_100) }
        let frameCount = Int(spec.duration * Double(spec.frameRate))
        for frame in 0..<frameCount {
            let time = Double(frame) / Double(spec.frameRate)
            try await tone?.append(until: time + audioLead, whileReady: true)
            // The writer may want audio further ahead than expected; feed it until video is accepted.
            // Audio is only offered while the writer takes it: when both inputs are busy (the hardware
            // encoder is shared with other tests), waiting on audio would deadlock with the video.
            var lead = audioLead
            let deadline = ContinuousClock.now + .seconds(5)
            while !video.isReadyForMoreMediaData, let current = tone, current.hasMore, ContinuousClock.now < deadline {
                if audio?.isReadyForMoreMediaData == true {
                    lead += audioLead
                    try await tone?.append(until: time + lead, whileReady: true)
                } else {
                    try await Task.sleep(for: .milliseconds(2))
                }
            }
            if let current = tone, !current.hasMore, let audio {
                // Without this the writer keeps waiting for audio to match the remaining video.
                audio.markAsFinished()
                tone = nil
            }
            try await waitUntilReady(video, writer: writer, label: "video frame \(frame)")
            guard let pool = adaptor.pixelBufferPool else { throw TestMediaError.writerFailed }
            let buffer = try makeFrame(index: frame, pool: pool)
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: spec.frameRate))
        }
        video.markAsFinished()
        if tone != nil {
            try await tone?.append(until: spec.duration)
            audio?.markAsFinished()
        }
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? TestMediaError.writerFailed }
    }

    static func audio(_ spec: AudioSpec = AudioSpec()) async throws -> URL {
        let ext =
            switch spec.fileType {
            case .m4a: "m4a"
            case .aiff: "aiff"
            default: "wav"
            }
        let url = sharedFolder.appendingPathComponent("audio-\(spec.hashValue).\(ext)")
        return try await fixtures.file(at: url) { try await writeAudio(spec, to: url) }
    }

    private static func writeAudio(_ spec: AudioSpec, to url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: spec.fileType)
        let input =
            spec.fileType == .m4a
            ? makeAACInput()
            : AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: spec.sampleRate,
                    AVNumberOfChannelsKey: 1,
                    AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsBigEndianKey: spec.fileType == .aiff,
                    AVLinearPCMIsNonInterleaved: false,
                ]
            )
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        var tone = SineWriter(input: input, totalDuration: spec.duration, sampleRate: spec.sampleRate)
        try await tone.append(until: spec.duration)
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? TestMediaError.writerFailed }
    }

    static func garbage(extension ext: String = "mp4") throws -> URL {
        let url = sharedFolder.appendingPathComponent("garbage-\(UUID().uuidString).\(ext)")
        let bytes = (0..<4096).map { _ in UInt8.random(in: 0...255) }
        try Data(bytes).write(to: url)
        return url
    }

    // MARK: Private

    private static let fixtures = FixtureRegistry()

    private static let audioLead: TimeInterval = 0.5
    // Generous: the whole suite runs in parallel and can starve the writer for seconds.
    fileprivate static let stallTimeout: Duration = .seconds(30)

    private static let sharedFolder: URL = {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("TrimlineTestMedia-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }()

    private static func makeAACInput() -> AVAssetWriterInput {
        AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 64_000,
            ]
        )
    }

    private static func makeFrame(index: Int, pool: CVPixelBufferPool) throws -> CVPixelBuffer {
        var output: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &output)
        guard let buffer = output else { throw TestMediaError.writerFailed }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw TestMediaError.writerFailed }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let pixels = base.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * rowBytes + x * 4
                pixels[offset] = UInt8((x + index * 4) % 256)
                pixels[offset + 1] = UInt8((y + index * 2) % 256)
                pixels[offset + 2] = UInt8((index * 8) % 256)
                pixels[offset + 3] = 255
            }
        }
        return buffer
    }

    fileprivate static func waitUntilReady(_ input: AVAssetWriterInput, writer: AVAssetWriter?, label: String)
        async throws
    {
        let deadline = ContinuousClock.now + stallTimeout
        while !input.isReadyForMoreMediaData {
            guard ContinuousClock.now < deadline else {
                throw TestMediaError.stalled(
                    "\(label), status \(writer?.status.rawValue ?? -1) \(String(describing: writer?.error))")
            }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    fileprivate static func makeSampleBuffer(
        _ samples: [Int16], start: Int, sampleRate: Double, format: CMAudioFormatDescription
    ) throws -> CMSampleBuffer {
        let byteCount = samples.count * MemoryLayout<Int16>.size
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: byteCount, blockAllocator: nil,
            customBlockSource: nil, offsetToData: 0, dataLength: byteCount, flags: 0, blockBufferOut: &block
        )
        guard let block else { throw TestMediaError.writerFailed }
        let status = samples.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return kCMBlockBufferBadPointerParameterErr }
            return CMBlockBufferReplaceDataBytes(
                with: base, blockBuffer: block, offsetIntoDestination: 0, dataLength: byteCount)
        }
        guard status == noErr else { throw TestMediaError.writerFailed }
        var buffer: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: samples.count,
            presentationTimeStamp: CMTime(value: CMTimeValue(start), timescale: CMTimeScale(sampleRate)),
            packetDescriptions: nil, sampleBufferOut: &buffer
        )
        guard let buffer else { throw TestMediaError.writerFailed }
        return buffer
    }
}

// Parallel tests ask for the same fixture at once; they share one write instead of racing on one file.
private actor FixtureRegistry {
    private var writes: [URL: Task<Void, any Error>] = [:]

    func file(at url: URL, write: @escaping @Sendable () async throws -> Void) async throws -> URL {
        let task = writes[url] ?? Task { try await write() }
        writes[url] = task
        try await task.value
        return url
    }
}

private struct SineWriter {
    let input: AVAssetWriterInput
    let totalDuration: TimeInterval
    let sampleRate: Double
    private var written = 0
    private var format: CMAudioFormatDescription?

    private static let frequency = 440.0
    private static let samplesPerBuffer = 4096

    init(input: AVAssetWriterInput, totalDuration: TimeInterval, sampleRate: Double) {
        self.input = input
        self.totalDuration = totalDuration
        self.sampleRate = sampleRate
    }

    var hasMore: Bool { written < Int(totalDuration * sampleRate) }

    mutating func append(until time: TimeInterval, whileReady: Bool = false) async throws {
        let format = try formatDescription()
        let target = Int(min(time, totalDuration) * sampleRate)
        while written < target {
            if whileReady, !input.isReadyForMoreMediaData { return }
            try await TestMedia.waitUntilReady(input, writer: nil, label: "audio sample \(written)")
            let count = min(Self.samplesPerBuffer, target - written)
            let start = written
            let samples = (0..<count).map { offset -> Int16 in
                let phase = 2 * Double.pi * Self.frequency * Double(start + offset) / sampleRate
                return Int16(sin(phase) * Double(Int16.max) * 0.8)
            }
            input.append(try TestMedia.makeSampleBuffer(samples, start: start, sampleRate: sampleRate, format: format))
            written += count
        }
    }

    private mutating func formatDescription() throws -> CMAudioFormatDescription {
        if let format { return format }
        var stream = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 2,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 16,
            mReserved: 0
        )
        var description: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(
            allocator: nil, asbd: &stream, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &description
        )
        guard let description else { throw TestMediaError.writerFailed }
        format = description
        return description
    }
}

enum TestMediaError: Error {
    case writerFailed
    case stalled(String)
}
