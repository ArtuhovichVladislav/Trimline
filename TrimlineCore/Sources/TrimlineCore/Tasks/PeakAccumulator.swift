import Accelerate

// Folds interleaved samples into a fixed number of min/max buckets as they stream in.
// The frame total is only an estimate from the header: extra frames go to the last bucket,
// and missing ones leave silent buckets at the end.
struct PeakAccumulator {
    let bucketCount: Int
    private let framesPerBucket: Double
    private(set) var completed: [Peak] = []
    private var current: Peak?
    private var frame = 0
    private var handedOut = 0

    private static let silence = Peak(min: 0, max: 0)

    init(bucketCount: Int, estimatedFrameCount: Int) {
        self.bucketCount = max(1, bucketCount)
        framesPerBucket = Double(max(1, estimatedFrameCount)) / Double(self.bucketCount)
        completed.reserveCapacity(self.bucketCount)
    }

    mutating func add(_ samples: UnsafeBufferPointer<Float>, channels: Int) {
        guard channels > 0 else { return }
        let frameCount = samples.count / channels
        var offset = 0
        while offset < frameCount {
            closeFinishedBuckets()
            let remaining = frameCount - offset
            let take = isOnLastBucket ? remaining : min(remaining, currentBucketEnd - frame)
            let slice = UnsafeBufferPointer(rebasing: samples[(offset * channels)..<((offset + take) * channels)])
            merge(Peak(min: vDSP.minimum(slice), max: vDSP.maximum(slice)))
            offset += take
            frame += take
        }
        closeFinishedBuckets()
    }

    mutating func takeChunk(minimumSize: Int) -> PeakChunk? {
        guard completed.count - handedOut >= max(1, minimumSize) else { return nil }
        return takeRemaining()
    }

    // Pads to exactly `bucketCount` and returns whatever has not been handed out yet.
    mutating func finish() -> PeakChunk? {
        if completed.count < bucketCount {
            completed.append(current ?? Self.silence)
            current = nil
        }
        completed.append(contentsOf: repeatElement(Self.silence, count: bucketCount - completed.count))
        return takeRemaining()
    }

    // MARK: Private

    private var isOnLastBucket: Bool { completed.count >= bucketCount - 1 }

    private var currentBucketEnd: Int {
        Int((Double(completed.count + 1) * framesPerBucket).rounded(.up))
    }

    private mutating func closeFinishedBuckets() {
        while !isOnLastBucket, frame >= currentBucketEnd {
            completed.append(current ?? Self.silence)
            current = nil
        }
    }

    private mutating func merge(_ peak: Peak) {
        guard let existing = current else {
            current = peak
            return
        }
        current = Peak(min: min(existing.min, peak.min), max: max(existing.max, peak.max))
    }

    private mutating func takeRemaining() -> PeakChunk? {
        guard handedOut < completed.count else { return nil }
        let chunk = PeakChunk(firstBucket: handedOut, peaks: Array(completed[handedOut...]))
        handedOut = completed.count
        return chunk
    }
}
