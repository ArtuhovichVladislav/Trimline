import AppKit
import SwiftUI

/// Scroll wheel and pinch over the timeline, which SwiftUI gestures don't deliver on macOS 14,
/// and ⌘= as Zoom In, since the menu's ⌘+ needs Shift on most layouts.
struct TimelineInputView: NSViewRepresentable {
    struct Handlers {
        /// Points towards later times; returns whether the timeline used the event.
        var scroll: @MainActor (CGFloat) -> Bool
        /// Zoom factor and the pointer's x in the timeline.
        var magnify: @MainActor (Double, CGFloat) -> Void
        var zoomIn: @MainActor () -> Void
    }

    let handlers: Handlers

    func makeNSView(context: Context) -> InputCatcherView {
        let view = InputCatcherView()
        view.handlers = handlers
        return view
    }

    func updateNSView(_ view: InputCatcherView, context: Context) {
        view.handlers = handlers
    }
}

final class InputCatcherView: NSView {
    private static let zoomInCharacter = "="
    private static let lineScrollDistance: CGFloat = 12

    var handlers: TimelineInputView.Handlers?
    private var monitor: Any?

    override var isFlipped: Bool { true }

    // Clicks and drags go to the SwiftUI gestures; this view only watches events through the monitor.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            removeMonitor()
        } else {
            installMonitor()
        }
    }

    private func installMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify, .keyDown]) { [weak self] event in
            let isHandled = MainActor.assumeIsolated { self?.handle(event) ?? false }
            return isHandled ? nil : event
        }
    }

    private func removeMonitor() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }

    private func handle(_ event: NSEvent) -> Bool {
        guard let window, event.window === window, let handlers else { return false }
        switch event.type {
        case .scrollWheel:
            return isInside(event) && handlers.scroll(scrollDistance(of: event))
        case .magnify:
            guard isInside(event) else { return false }
            handlers.magnify(1 + event.magnification, convert(event.locationInWindow, from: nil).x)
            return true
        case .keyDown:
            guard isZoomInKey(event), window.isKeyWindow, window.attachedSheet == nil else { return false }
            handlers.zoomIn()
            return true
        default:
            return false
        }
    }

    private func isInside(_ event: NSEvent) -> Bool {
        bounds.contains(convert(event.locationInWindow, from: nil))
    }

    // A plain mouse wheel scrolls vertically; over the timeline either axis moves through time.
    private func scrollDistance(of event: NSEvent) -> CGFloat {
        let isHorizontal = abs(event.scrollingDeltaX) >= abs(event.scrollingDeltaY)
        let delta = isHorizontal ? event.scrollingDeltaX : event.scrollingDeltaY
        return -(event.hasPreciseScrollingDeltas ? delta : delta * Self.lineScrollDistance)
    }

    private func isZoomInKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return modifiers.contains(.command) && modifiers.isDisjoint(with: [.shift, .control, .option])
            && event.charactersIgnoringModifiers == Self.zoomInCharacter
    }
}
