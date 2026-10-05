import AppKit
import SwiftUI
import TrimlineCore

/// Turns pointer drags on the timeline into model calls and scrolls a zoomed timeline
/// while the pointer is held near an edge.
@MainActor
final class TimelineDragController {
    struct Context {
        let model: EditorModel
        let interaction: InteractionState
        let width: CGFloat
        let handleWidth: CGFloat
        let knobHeight: CGFloat

        @MainActor var geometry: TimelineGeometry {
            TimelineGeometry(width: width, handleWidth: handleWidth, viewport: interaction.viewport)
        }
    }

    // Offsets are measured in time from where the drag grabbed, so they survive auto-scrolling.
    private enum Action {
        case handle(EditorModel.TrimHandle, startTime: TimeInterval, grabTime: TimeInterval)
        case selection(startTime: TimeInterval, grabTime: TimeInterval, isMoving: Bool)
        case scrub
    }

    private static let moveThreshold: CGFloat = 3
    private static let autoScrollTick: Duration = .milliseconds(16)

    private var action: Action?
    private var startX: CGFloat = 0
    private var pointerX: CGFloat = 0
    private var autoScrollTask: Task<Void, Never>?

    var isDragging: Bool { action != nil }

    func change(from start: CGPoint, to location: CGPoint, _ context: Context) {
        if action == nil {
            startX = start.x
            action = begin(at: start, context)
        }
        pointerX = location.x
        apply(context)
        updateAutoScroll(context)
        if let action {
            Self.cursor(for: action).set()
        }
    }

    func end(at location: CGPoint, _ context: Context) {
        stopAutoScroll()
        if let action {
            finish(action, at: location.x, context)
        }
        action = nil
        Self.cursor(for: target(at: location, context)).set()
    }

    func hover(_ phase: HoverPhase, _ context: Context) {
        guard action == nil else { return }
        switch phase {
        case .active(let location):
            Self.cursor(for: target(at: location, context)).set()
        case .ended:
            NSCursor.arrow.set()
        }
    }

    // MARK: Actions

    // The playhead knob sits above the track, so anything grabbed up there is the playhead.
    private func target(at location: CGPoint, _ context: Context) -> TimelineGeometry.Target {
        if location.y < context.knobHeight { return .playhead }
        return context.geometry.target(
            at: location.x, selection: context.model.selection, playhead: context.model.currentTime)
    }

    private func begin(at location: CGPoint, _ context: Context) -> Action {
        let grabTime = context.geometry.time(at: location.x)
        switch target(at: location, context) {
        case .handle(let handle):
            context.interaction.selectedHandle = handle
            context.model.beginDragging(handle)
            return .handle(handle, startTime: context.model.handleTime(handle), grabTime: grabTime)
        case .selection:
            return .selection(startTime: context.model.selection.start, grabTime: grabTime, isMoving: false)
        case .playhead, .track:
            context.interaction.selectedHandle = nil
            return .scrub
        }
    }

    private func apply(_ context: Context) {
        guard let action else { return }
        let geometry = context.geometry
        let pointerTime = geometry.time(at: min(max(pointerX, 0), context.width))
        switch action {
        case .handle(let handle, let startTime, let grabTime):
            context.model.drag(handle, to: startTime + pointerTime - grabTime)
        case .selection(let startTime, let grabTime, let isMoving):
            guard isMoving || abs(pointerX - startX) >= Self.moveThreshold else { return }
            let target = startTime + pointerTime - grabTime
            context.model.moveSelection(by: target - context.model.selection.start)
            self.action = .selection(startTime: startTime, grabTime: grabTime, isMoving: true)
        case .scrub:
            context.model.scrub(to: geometry.visibleTime(at: pointerX))
        }
    }

    private func finish(_ action: Action, at x: CGFloat, _ context: Context) {
        switch action {
        case .handle(let handle, _, _):
            context.model.endDragging(handle)
        case .selection(_, _, isMoving: true):
            context.model.endMovingSelection()
        case .selection(_, _, isMoving: false):
            context.interaction.selectedHandle = nil
            context.model.seek(to: context.geometry.visibleTime(at: x))
        case .scrub:
            context.model.seek(to: context.geometry.visibleTime(at: x))
        }
    }

    // MARK: Auto-scrolling

    private func updateAutoScroll(_ context: Context) {
        guard context.geometry.autoScrollVelocity(at: pointerX) != 0 else {
            stopAutoScroll()
            return
        }
        guard autoScrollTask == nil else { return }
        autoScrollTask = Task { [weak self] in
            var last = ContinuousClock.now
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.autoScrollTick)
                let now = ContinuousClock.now
                guard let self, !Task.isCancelled, self.autoScroll(for: now - last, context) else { return }
                last = now
            }
        }
    }

    /// Returns false once the pointer is out of the edge zone or the drag is over.
    private func autoScroll(for elapsed: Duration, _ context: Context) -> Bool {
        let geometry = context.geometry
        let velocity = geometry.autoScrollVelocity(at: pointerX)
        guard action != nil, velocity != 0 else {
            autoScrollTask = nil
            return false
        }
        let distance = TimeInterval(velocity) * (elapsed / .seconds(1))
        context.interaction.viewport.scroll(by: distance * geometry.secondsPerPoint)
        apply(context)
        return true
    }

    private func stopAutoScroll() {
        autoScrollTask?.cancel()
        autoScrollTask = nil
    }

    // MARK: Cursor

    private static func cursor(for target: TimelineGeometry.Target) -> NSCursor {
        switch target {
        case .handle, .playhead: .resizeLeftRight
        case .selection: .openHand
        case .track: .arrow
        }
    }

    private static func cursor(for action: Action) -> NSCursor {
        switch action {
        case .handle, .scrub: .resizeLeftRight
        case .selection(_, _, isMoving: true): .closedHand
        case .selection(_, _, isMoving: false): .openHand
        }
    }
}
