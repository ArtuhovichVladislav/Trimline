import CoreMedia
import libavcodec

/// Passes H.264 and HEVC packets through untouched, so the display layer decodes them with VideoToolbox.
final class CompressedVideoSource: PlaybackSource {
    private let format: PlaybackVideoFormat
    private let timing: StreamTiming
    private var start = CMTime.zero
    private var awaitsKeyframe = true
    private var awaitsFirstShownFrame = true
    private var description: CMVideoFormatDescription
    private var parameterSets: [[UInt8]]?

    init(format: PlaybackVideoFormat, timing: StreamTiming) {
        self.format = format
        self.timing = timing
        description = format.description
        parameterSets = format.bitstream?.parameterSets
    }

    func restart(at start: CMTime) {
        self.start = start
        awaitsKeyframe = true
        awaitsFirstShownFrame = true
    }

    func append(_ packet: Packet, to output: inout [CMSampleBuffer]) {
        if awaitsKeyframe, !packet.isKeyframe { return }
        awaitsKeyframe = false
        guard let presentation = timing.time(packet.pts) ?? timing.time(packet.dts) else { return }
        let duration = timing.duration(packet.duration)
        // Matroska leaves the first decode timestamps unset; the layer decodes in enqueue order anyway.
        let timingInfo = CMSampleTimingInfo(
            duration: duration, presentationTimeStamp: presentation, decodeTimeStamp: .invalid)
        guard let sample = makeSample(from: packet, timing: timingInfo) else { return }

        if !packet.isKeyframe {
            PlaybackBuffers.setAttachment(kCMSampleAttachmentKey_NotSync, on: sample)
        }
        // Frames before the seek target still have to be decoded as references, just not shown.
        if presentation + duration <= start {
            PlaybackBuffers.setAttachment(kCMSampleAttachmentKey_DoNotDisplay, on: sample)
        } else if awaitsFirstShownFrame {
            awaitsFirstShownFrame = false
            // Only a key frame can be trusted to be the earliest one shown; later ones may be reordered.
            if packet.isKeyframe, presentation > start {
                PlaybackBuffers.setAttachment(kCMSampleAttachmentKey_DisplayImmediately, on: sample)
            }
        }
        output.append(sample)
    }

    func drain(to output: inout [CMSampleBuffer]) {}

    private func makeSample(from packet: Packet, timing: CMSampleTimingInfo) -> CMSampleBuffer? {
        guard let data = packet.pointer.pointee.data else { return nil }
        let bytes = UnsafeRawBufferPointer(start: data, count: packet.size)
        let block: CMBlockBuffer?
        if format.usesStartCodes {
            block = PlaybackNALUnits.lengthPrefixed(fromAnnexB: bytes).withUnsafeBytes {
                PlaybackBuffers.blockBuffer(copying: $0)
            }
        } else {
            block = PlaybackBuffers.blockBuffer(copying: bytes)
        }
        guard let block else { return nil }
        if packet.isKeyframe {
            followParameterSets(in: bytes)
        }
        var timing = timing
        var size = CMBlockBufferGetDataLength(block)
        var sample: CMSampleBuffer?
        let status = CMSampleBufferCreateReady(
            allocator: nil, dataBuffer: block, formatDescription: description, sampleCount: 1,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1,
            sampleSizeArray: &size, sampleBufferOut: &sample)
        return status == noErr ? sample : nil
    }

    /// A key frame with parameter sets of its own, unlike the stream header's, gets a description of
    /// its own; the header's comes back with the header's sets.
    private func followParameterSets(in bytes: UnsafeRawBufferPointer) {
        guard let bitstream = format.bitstream, let sets = bitstream.parameterSets(in: bytes), sets != parameterSets
        else { return }
        if sets == bitstream.parameterSets {
            description = format.description
        } else if let changed = format.description(for: sets) {
            description = changed
        } else {
            return
        }
        parameterSets = sets
    }
}
