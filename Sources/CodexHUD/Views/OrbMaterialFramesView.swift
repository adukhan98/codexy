import AppKit
import QuartzCore

/// Presents one fully composited orb image at a time. The material frames are
/// rendered once by SwiftUI, while Core Animation advances the layer contents
/// without rebuilding gradients, paths, blur, or texture on the main thread.
///
/// A single contents layer is deliberate: opacity-crossfading transparent orb
/// poses changes their effective alpha and causes visible luminance pumping.
@MainActor
final class OrbMaterialFramesView: NSView {
    private let imageLayer = CALayer()
    private var contentPadding: CGFloat = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureView()
    }

    func configure(
        frames: [CGImage],
        contentsScale: CGFloat,
        contentPadding: CGFloat,
        cycleDuration: Double,
        referenceMediaTime: CFTimeInterval,
        animates: Bool
    ) {
        imageLayer.removeAllAnimations()
        self.contentPadding = max(0, contentPadding)
        updateImageLayerFrame()

        guard let firstFrame = frames.first else {
            imageLayer.contents = nil
            return
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contentsScale = contentsScale
        imageLayer.contentsGravity = .resize
        imageLayer.contents = firstFrame
        CATransaction.commit()

        guard animates, frames.count > 1 else { return }

        let frameCount = frames.count
        let animation = CAKeyframeAnimation(keyPath: "contents")
        animation.values = frames
        animation.keyTimes = (0..<frameCount).map {
            NSNumber(value: Double($0) / Double(frameCount))
        }
        animation.duration = cycleDuration
        let localTime = imageLayer.convertTime(
            referenceMediaTime,
            from: nil
        )
        animation.beginTime = localTime
        animation.timeOffset = localTime
            .truncatingRemainder(dividingBy: cycleDuration)
        animation.repeatCount = .infinity
        animation.calculationMode = .discrete
        animation.isRemovedOnCompletion = false
        imageLayer.add(animation, forKey: "orbMaterialFrames")
    }

    override func layout() {
        super.layout()
        updateImageLayerFrame()
    }

    private func configureView() {
        wantsLayer = true
        layer?.masksToBounds = false
        imageLayer.masksToBounds = false
        imageLayer.minificationFilter = .trilinear
        imageLayer.magnificationFilter = .linear
        layer?.addSublayer(imageLayer)
        setAccessibilityElement(false)
    }

    private func updateImageLayerFrame() {
        let target = bounds.insetBy(
            dx: -contentPadding,
            dy: -contentPadding
        )
        guard imageLayer.frame != target else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.frame = target
        CATransaction.commit()
    }
}
