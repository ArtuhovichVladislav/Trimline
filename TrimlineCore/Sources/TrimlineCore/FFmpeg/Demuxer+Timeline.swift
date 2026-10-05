import Foundation
import libavcodec
import libavformat
import libavutil

extension Demuxer {
    /// The file's earliest timestamp. The editor's time 0 is this moment, so MPEG-TS files that start
    /// at an arbitrary clock value still begin at 0 on the timeline.
    var timelineOrigin: TimeInterval {
        let start = context.pointee.start_time
        guard start != FFmpegTime.noValue, start > 0 else { return 0 }
        return Double(start) / Double(FFmpegTime.microsecondsPerSecond)
    }

    /// Makes the demuxer drop packets of every other stream before they are copied out of the file.
    func discardAllStreams(except index: Int) {
        for stream in streams where stream.index != index {
            self.stream(stream.index)?.pointee.discard = AVDISCARD_ALL
        }
    }
}
