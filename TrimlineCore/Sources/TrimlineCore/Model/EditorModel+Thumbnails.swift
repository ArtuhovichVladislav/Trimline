import Foundation

extension EditorModel {
    public func requestThumbnails(count: Int, height: Int) {
        guard let info else { return }
        requestThumbnails(count: count, height: height, in: 0...info.duration)
    }

    /// Replaces the strip with `count` thumbnails of `range`, keeping the last finished strip
    /// in `previousThumbnails` until the new one is complete.
    public func requestThumbnails(count: Int, height: Int, in range: ClosedRange<TimeInterval>) {
        guard let engine, engine.info.kind == .video, count > 0 else { return }
        let range = range.clamped(to: 0...engine.info.duration)
        thumbnailTask?.cancel()
        if !thumbnails.isEmpty, thumbnails.isFinished || previousThumbnails == nil {
            previousThumbnails = thumbnails
        }
        thumbnails = ThumbnailSet(range: range, count: count)
        thumbnailTask = Task { [weak self] in
            for await thumbnail in engine.thumbnails(count: count, height: height, in: range) {
                guard let self, !Task.isCancelled else { return }
                self.thumbnails.insert(thumbnail)
            }
            guard let self, !Task.isCancelled else { return }
            self.thumbnails.isFinished = true
            self.previousThumbnails = nil
        }
    }
}
