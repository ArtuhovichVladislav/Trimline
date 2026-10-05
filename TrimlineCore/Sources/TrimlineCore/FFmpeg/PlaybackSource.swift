import CoreMedia
import Foundation
import libavutil

enum PlaybackTrack: Sendable, Hashable, CaseIterable {
    case video
    case audio
}

/// What the pipeline found in the file, as far as the renderers need to know.
struct PlaybackLayout: Sendable {
    /// How far ahead of the clock each track may be fed; decoded frames are large, so they get less.
    let lookahead: [PlaybackTrack: TimeInterval]
    /// Clockwise quarter turns, 0...3.
    let quarterTurns: Int

    var tracks: [PlaybackTrack] { PlaybackTrack.allCases.filter { lookahead[$0] != nil } }
}

/// A ready sample buffer on its way from the pipeline actor to a renderer.
struct PlaybackSample: @unchecked Sendable {
    // Nothing mutates a sample buffer after it is created, so handing it to another actor is safe.
    let buffer: CMSampleBuffer

    var presentationTime: TimeInterval { buffer.presentationTimeStamp.seconds }
}

/// Turns the packets of one stream into sample buffers that a renderer can take as they are.
protocol PlaybackSource: AnyObject {
    func append(_ packet: Packet, to output: inout [CMSampleBuffer])

    /// Called once at the end of the file to get frames the decoder still holds.
    func drain(to output: inout [CMSampleBuffer])

    /// Called after every seek: nothing that ends before `start` may be shown or heard.
    func restart(at start: CMTime)
}

/// Converts a stream's timestamps to the editor's timeline, which starts at zero.
struct StreamTiming {
    let timeBase: AVRational
    let origin: CMTime
    /// Used when a packet or frame has no duration of its own.
    let fallbackDuration: CMTime

    func time(_ timestamp: Int64) -> CMTime? {
        let time = FFmpegTime.cmTime(timestamp, in: timeBase)
        return time.isValid ? time - origin : nil
    }

    func duration(_ value: Int64) -> CMTime {
        value > 0 ? FFmpegTime.cmTime(value, in: timeBase) : fallbackDuration
    }
}

enum PlaybackBuffers {
    static func setAttachment(_ key: CFString, on sample: CMSampleBuffer) {
        guard
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true)
                as? [NSMutableDictionary],
            let first = attachments.first
        else { return }
        first[key] = true
    }

    static func blockBuffer(copying bytes: UnsafeRawBufferPointer) -> CMBlockBuffer? {
        guard let base = bytes.baseAddress, !bytes.isEmpty else { return nil }
        var block: CMBlockBuffer?
        let created = CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: bytes.count, blockAllocator: nil,
            customBlockSource: nil, offsetToData: 0, dataLength: bytes.count,
            flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
        guard created == noErr, let block else { return nil }
        let copied = CMBlockBufferReplaceDataBytes(
            with: base, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes.count)
        return copied == noErr ? block : nil
    }
}
