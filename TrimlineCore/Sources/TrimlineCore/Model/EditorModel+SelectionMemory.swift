import Foundation

// A reopened file gets back the selection it was left with and the playhead goes to the clip start.
// The bounds are restored as stored: a dragged start was already snapped to its key frame, a typed one
// stays exact, as in the session that set it. Restoring is not an undo step.
extension EditorModel {
    /// Writes the current selection without waiting for the pause after the last change (for quitting).
    public func rememberSelectionNow() async {
        await selectionRecall.flush(selection)
    }

    /// Forgets every remembered selection, the open file's included (Open Recent ▸ Clear Menu).
    public func forgetRememberedSelections() {
        selectionRecall.forgetAll()
    }

    func applyRemembered(_ lookup: SelectionRecall.Lookup?) {
        guard let lookup else { return }
        if let range = lookup.range, range.lowerBound < selection.duration {
            selection = Selection(duration: selection.duration, start: range.lowerBound, end: range.upperBound)
        }
        selectionRecall.track(lookup.file)
    }
}

/// Connects the model to its `SelectionMemory`: looks the file up while it opens and writes the selection
/// a moment after it stops changing and when the file is closed, never on every frame of a drag.
@MainActor
final class SelectionRecall {
    struct Lookup: Sendable {
        let file: FileFingerprint
        let range: ClosedRange<TimeInterval>?
    }

    static let writeDelay: Duration = .seconds(1)

    private let memory: (any SelectionMemory)?
    private var file: FileFingerprint?
    private var latest: Selection?
    private var delayedWrite: Task<Void, Never>?
    // Memory calls run one after another, so reopening a file sees the write made when it was closed.
    private var lastOperation: Task<Void, Never>?

    init(memory: (any SelectionMemory)?) {
        self.memory = memory
    }

    func lookUp(_ url: URL) -> Task<Lookup?, Never>? {
        guard let memory else { return nil }
        let previous = lastOperation
        return Task.detached {
            await previous?.value
            guard let file = FileFingerprint(of: url) else { return nil }
            return Lookup(file: file, range: await memory.selection(for: file))
        }
    }

    func track(_ file: FileFingerprint) {
        self.file = file
        latest = nil
    }

    func selectionChanged(_ selection: Selection) {
        guard file != nil else { return }
        latest = selection
        guard delayedWrite == nil else { return }
        delayedWrite = Task { [weak self] in
            try? await Task.sleep(for: Self.writeDelay)
            guard let self, !Task.isCancelled else { return }
            self.delayedWrite = nil
            if let latest = self.latest {
                self.write(latest)
            }
        }
    }

    func close(with selection: Selection) {
        write(selection)
        file = nil
    }

    func flush(_ selection: Selection) async {
        write(selection)
        await lastOperation?.value
    }

    func forgetAll() {
        cancelDelayedWrite()
        file = nil
        guard let memory else { return }
        enqueue { await memory.forgetAll() }
    }

    // The whole file is the default, so it is forgotten rather than stored.
    private func write(_ selection: Selection) {
        cancelDelayedWrite()
        guard let memory, let file else { return }
        if selection.coversWholeFile {
            enqueue { await memory.forget(file) }
        } else {
            let range = selection.range
            enqueue { await memory.remember(range, for: file) }
        }
    }

    private func cancelDelayedWrite() {
        delayedWrite?.cancel()
        delayedWrite = nil
        latest = nil
    }

    private func enqueue(_ operation: @escaping @Sendable () async -> Void) {
        let previous = lastOperation
        lastOperation = Task {
            await previous?.value
            await operation()
        }
    }
}
