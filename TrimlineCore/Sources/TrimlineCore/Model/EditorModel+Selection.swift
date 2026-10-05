import Foundation

// When fast saving can't start between key frames (containers without edit lists), the start snaps to
// the previous key frame when a drag ends or on I. Typed times and arrow nudges stay exact; the save
// panel shows the real bounds.
// The playhead stays within the selection: dragging an edge or the whole selection previews the edge frame
// and leaves the playhead in place unless an edge runs into it, then the edge pushes it along.
extension EditorModel {
    public func beginDragging(_ handle: TrimHandle) {
        pausePlayback()
        draggedHandle = handle
        beginGesture()
    }

    public func drag(_ handle: TrimHandle, to time: TimeInterval) {
        applyHandle(handle, to: time)
        previewFrame(at: handleTime(handle))
    }

    public func endDragging(_ handle: TrimHandle) {
        draggedHandle = nil
        let unrecordedStart = finishGesture()
        showFrame(at: currentTime)
        if handle == .start {
            snapStartToKeyframe(recordingFrom: unrecordedStart)
        }
    }

    /// The first move of a drag starts the gesture; `endMovingSelection()` ends it.
    public func moveSelection(by offset: TimeInterval) {
        if gestureStart == nil {
            pausePlayback()
            beginGesture()
        }
        selection.move(by: offset)
        previewFrame(at: selection.start)
    }

    public func endMovingSelection() {
        let unrecordedStart = finishGesture()
        showFrame(at: currentTime)
        snapStartToKeyframe(recordingFrom: unrecordedStart)
    }

    /// Sets a handle to an exact time (a typed value) as one undo step.
    public func setHandle(_ handle: TrimHandle, to time: TimeInterval) {
        recordingStep { applyHandle(handle, to: time) }
    }

    public func nudge(_ handle: TrimHandle, frames: Int) {
        guard let info else { return }
        setHandle(handle, to: handleTime(handle) + Double(frames) * info.frameStep)
        showFrame(at: handleTime(handle))
    }

    public func nudge(_ handle: TrimHandle, seconds: TimeInterval) {
        setHandle(handle, to: handleTime(handle) + seconds)
        showFrame(at: handleTime(handle))
    }

    public func markStart() {
        let before = selection
        applyHandle(.start, to: currentTime)
        snapStartToKeyframe(recordingFrom: recordStep(from: before) ? nil : before)
    }

    public func markEnd() {
        setHandle(.end, to: currentTime)
    }

    public func resetSelection() {
        recordingStep { selection.reset() }
        seek(to: 0)
        restartPlaybackIfNeeded()
    }

    public func handleTime(_ handle: TrimHandle) -> TimeInterval {
        handle == .start ? selection.start : selection.end
    }

    // MARK: Private

    private func applyHandle(_ handle: TrimHandle, to time: TimeInterval) {
        switch handle {
        case .start: selection.setStart(time)
        case .end: selection.setEnd(time)
        }
        if draggedHandle == nil {
            restartPlaybackIfNeeded()
        }
    }

    /// `undoBaseline` is set when the gesture that led here recorded no step of its own.
    private func snapStartToKeyframe(recordingFrom undoBaseline: Selection?) {
        guard let engine, startsOnKeyframe(engine.info) else { return }
        let requested = selection.start
        snapTask?.cancel()
        snapTask = Task { [weak self] in
            let keyframe = await engine.keyframe(atOrBefore: requested)
            // Drop the result if the user has moved the handle again in the meantime.
            guard let self, !Task.isCancelled, self.selection.start == requested else { return }
            self.selection.setStart(keyframe)
            if let undoBaseline {
                self.recordStep(from: undoBaseline)
            }
            self.restartPlaybackIfNeeded()
        }
    }

    private func showFrame(at time: TimeInterval) {
        guard !isPlaying else { return }
        seek(to: time)
    }

    func startsOnKeyframe(_ info: MediaInfo) -> Bool {
        effectiveExportMode == .fast && info.kind == .video && effectiveExportContent.keepsVideo
            && !StreamCopyStart.isExact(for: info.url)
    }
}
