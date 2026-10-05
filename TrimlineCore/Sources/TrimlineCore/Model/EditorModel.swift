import Foundation
import Observation

@MainActor
@Observable
public final class EditorModel {
    public enum Phase: Equatable {
        case empty
        case loading(URL)
        case ready
        case failed(URL, MediaOpenError)
    }

    public enum TrimHandle: Sendable {
        case start
        case end
    }

    public typealias Opener = @Sendable (URL) async throws(MediaOpenError) -> any MediaEngine

    // MARK: State

    public private(set) var phase: Phase = .empty
    public private(set) var info: MediaInfo?
    public internal(set) var selection = Selection(duration: 0) {
        didSet {
            keepPlayheadInSelection()
            selectionRecall.selectionChanged(selection)
        }
    }
    public private(set) var currentTime: TimeInterval = 0
    public private(set) var isPlaying = false
    public private(set) var isLooping = false
    public private(set) var playback: (any PlaybackController)?
    public private(set) var showsLoadingIndicator = false
    public private(set) var requestedFileCount = 0
    public internal(set) var thumbnails = ThumbnailSet.empty
    /// Shown under `thumbnails` until they finish loading, so zooming never flashes an empty strip.
    public internal(set) var previousThumbnails: ThumbnailSet?
    public private(set) var waveform: [Peak] = []
    public internal(set) var draggedHandle: TrimHandle?
    /// The app's setting: `.precise` cuts video to the exact frame.
    public var exportMode: ExportMode = .fast {
        didSet { if exportMode != oldValue { refreshSaveProposal() } }
    }
    /// Chosen per file in the save sheet; every file starts with both picture and sound.
    public var exportContent: ExportContent = .videoAndSound {
        didSet { if exportContent != oldValue { refreshSaveProposal() } }
    }
    /// Choose the clip's location in a save panel even when the original's folder is writable.
    public var alwaysAsksForDestination = false
    public internal(set) var history = SelectionHistory()
    public internal(set) var saveState: SaveState = .idle
    public internal(set) var frameExport: FrameExportState = .idle

    // MARK: Dependencies and tasks

    @ObservationIgnored let opener: Opener
    @ObservationIgnored let exporter: Exporter
    @ObservationIgnored let selectionRecall: SelectionRecall
    @ObservationIgnored public var naming: FileNaming
    @ObservationIgnored public var onHistoryChange: ((SelectionHistory.Change) -> Void)?
    @ObservationIgnored var gestureStart: Selection?
    @ObservationIgnored var engine: (any MediaEngine)?
    @ObservationIgnored private var openTask: Task<Void, Never>?
    @ObservationIgnored private var indicatorTask: Task<Void, Never>?
    @ObservationIgnored var thumbnailTask: Task<Void, Never>?
    @ObservationIgnored private var waveformTask: Task<Void, Never>?
    // A preview reports the key frame it landed on or the trim edge it shows;
    // either would pull the playhead off the pointer or its place.
    @ObservationIgnored private var isPreviewingFrame = false
    @ObservationIgnored var snapTask: Task<Void, Never>?
    @ObservationIgnored var saveTask: Task<Void, Never>?
    @ObservationIgnored public var frameNaming = FrameNaming()
    @ObservationIgnored var frameTask: Task<Void, Never>?
    @ObservationIgnored var frameRender: FrameRender?

    public static let waveformBucketCount = 2400
    static let loadingIndicatorDelay: Duration = .milliseconds(300)
    public static let longSkip: TimeInterval = 5
    public static let shortSkip: TimeInterval = 1

    public init(
        clipSuffix: String,
        exporter: Exporter = Exporter(),
        opener: @escaping Opener = { url throws(MediaOpenError) in try await MediaOpener.open(url) },
        selectionMemory: (any SelectionMemory)? = nil
    ) {
        self.naming = FileNaming(suffix: clipSuffix)
        self.exporter = exporter
        self.opener = opener
        self.selectionRecall = SelectionRecall(memory: selectionMemory)
    }

    // MARK: Opening

    public func open(_ urls: [URL]) {
        guard let first = urls.first else { return }
        open(first)
        requestedFileCount = urls.count
    }

    public func open(_ url: URL) {
        closeCurrentFile()
        phase = .loading(url)
        requestedFileCount = 1

        indicatorTask = Task { [weak self] in
            try? await Task.sleep(for: Self.loadingIndicatorDelay)
            guard !Task.isCancelled, let self, case .loading = self.phase else { return }
            self.showsLoadingIndicator = true
        }
        let remembered = selectionRecall.lookUp(url)
        openTask = Task { [weak self, opener] in
            do throws(MediaOpenError) {
                let engine = try await opener(url)
                let lookup = await remembered?.value
                guard !Task.isCancelled else { return }
                self?.didOpen(engine, remembered: lookup)
            } catch {
                guard !Task.isCancelled else { return }
                self?.didFailToOpen(url, error: error)
            }
        }
    }

    public func closeCurrentFile() {
        selectionRecall.close(with: selection)
        for task in [openTask, indicatorTask, thumbnailTask, waveformTask, snapTask, saveTask] {
            task?.cancel()
        }
        playback?.close()
        playback = nil
        engine = nil
        info = nil
        phase = .empty
        requestedFileCount = 0
        selection = Selection(duration: 0)
        currentTime = 0
        isPreviewingFrame = false
        isPlaying = false
        showsLoadingIndicator = false
        thumbnails = .empty
        previousThumbnails = nil
        waveform = []
        draggedHandle = nil
        saveState = .idle
        cancelFrameExport()
        exportContent = .videoAndSound
        clearHistory()
    }

    private func didOpen(_ engine: any MediaEngine, remembered: SelectionRecall.Lookup?) {
        let player = engine.makePlayback()
        player.onTimeChange = { [weak self] time in
            guard let self, !self.isPreviewingFrame else { return }
            self.currentTime = time
        }
        player.onPlaybackStop = { [weak self] in self?.isPlaying = false }

        self.engine = engine
        info = engine.info
        selection = Selection(duration: engine.info.duration)
        playback = player
        currentTime = 0
        showsLoadingIndicator = false
        indicatorTask?.cancel()
        phase = .ready
        applyRemembered(remembered)

        if engine.info.kind == .audio {
            loadWaveform(from: engine)
        }
    }

    private func didFailToOpen(_ url: URL, error: MediaOpenError) {
        indicatorTask?.cancel()
        showsLoadingIndicator = false
        phase = .failed(url, error)
    }

    // MARK: Timeline images

    private func loadWaveform(from engine: any MediaEngine) {
        waveform = Array(repeating: Peak(min: 0, max: 0), count: Self.waveformBucketCount)
        waveformTask = Task { [weak self] in
            for await chunk in engine.peaks(buckets: Self.waveformBucketCount) {
                guard let self, !Task.isCancelled else { return }
                for (offset, peak) in chunk.peaks.enumerated() {
                    let bucket = chunk.firstBucket + offset
                    if self.waveform.indices.contains(bucket) {
                        self.waveform[bucket] = peak
                    }
                }
            }
        }
    }

    // MARK: Playback

    public func togglePlayback() {
        guard let playback else { return }
        isPreviewingFrame = false
        if isPlaying {
            playback.pause()
            isPlaying = false
        } else {
            playback.play(within: selection.range, looping: isLooping)
            isPlaying = true
        }
    }

    public func toggleLooping() {
        isLooping.toggle()
        restartPlaybackIfNeeded()
    }

    public func skip(by offset: TimeInterval) {
        seek(to: currentTime + offset)
    }

    public func step(frames: Int) {
        guard let info else { return }
        pausePlayback()
        seek(to: currentTime + Double(frames) * info.frameStep)
    }

    public func seek(to time: TimeInterval) {
        guard let playback else { return }
        let target = time.clamped(to: selection.range)
        isPreviewingFrame = false
        currentTime = target
        playback.seek(to: target, precise: true)
    }

    // While dragging the playhead the preview follows with fast key-frame seeks; the release does a precise one.
    public func scrub(to time: TimeInterval) {
        pausePlayback()
        currentTime = time.clamped(to: selection.range)
        previewFrame(at: currentTime)
    }

    /// Shows a frame without moving the playhead; a precise `seek(to:)` ends the preview.
    func previewFrame(at time: TimeInterval) {
        guard let playback else { return }
        isPreviewingFrame = true
        playback.seek(to: time, precise: false)
    }

    // During a drag the preview shows the edge being moved; the release shows the playhead's frame.
    private func keepPlayheadInSelection() {
        guard !selection.range.contains(currentTime) else { return }
        currentTime = currentTime.clamped(to: selection.range)
        if gestureStart == nil, !isPlaying {
            seek(to: currentTime)
        }
    }

    func pausePlayback() {
        guard isPlaying else { return }
        playback?.pause()
        isPlaying = false
    }

    func restartPlaybackIfNeeded() {
        guard isPlaying, let playback else { return }
        playback.play(within: selection.range, looping: isLooping)
    }
}
