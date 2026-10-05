import AVFoundation
import QuartzCore

/// Holds the display layer and turns it for rotated videos. The host view only sets this layer's frame,
/// so the turn has to live inside it.
final class PlaybackSurfaceLayer: CALayer {
    let displayLayer: AVSampleBufferDisplayLayer

    /// Clockwise quarter turns, 0...3.
    var quarterTurns = 0 {
        didSet { setNeedsLayout() }
    }

    private static let quarterTurnAngle = CGFloat.pi / 2

    override init() {
        displayLayer = AVSampleBufferDisplayLayer()
        super.init()
        displayLayer.videoGravity = .resizeAspect
        addSublayer(displayLayer)
    }

    // Core Animation copies layers this way for their presentation versions.
    override init(layer: Any) {
        displayLayer = (layer as? PlaybackSurfaceLayer)?.displayLayer ?? AVSampleBufferDisplayLayer()
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layoutSublayers() {
        super.layoutSublayers()
        let size = quarterTurns.isMultiple(of: 2) ? bounds.size : CGSize(width: bounds.height, height: bounds.width)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.bounds = CGRect(origin: .zero, size: size)
        displayLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        // Layer space has y pointing up, so a clockwise turn is a negative angle.
        displayLayer.setAffineTransform(
            CGAffineTransform(rotationAngle: -CGFloat(quarterTurns) * Self.quarterTurnAngle))
        CATransaction.commit()
    }
}
