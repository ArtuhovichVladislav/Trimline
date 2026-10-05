import AppKit
import SwiftUI

/// Hosts the engine's video layer (AVPlayerLayer or AVSampleBufferDisplayLayer).
struct VideoSurfaceView: NSViewRepresentable {
    let surface: CALayer?

    func makeNSView(context: Context) -> SurfaceHostView {
        SurfaceHostView()
    }

    func updateNSView(_ view: SurfaceHostView, context: Context) {
        view.surface = surface
    }
}

final class SurfaceHostView: NSView {
    var surface: CALayer? {
        didSet {
            guard oldValue !== surface else { return }
            oldValue?.removeFromSuperlayer()
            if let surface {
                layer?.addSublayer(surface)
            }
            needsLayout = true
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        // Without this the layer animates to every new size while the window is resized.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        surface?.frame = bounds
        CATransaction.commit()
    }
}
