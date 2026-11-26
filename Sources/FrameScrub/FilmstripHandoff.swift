import AppKit
import HomeChrome

/// Animates the picture surfaces independently of either strip's seek feedback.
@MainActor enum FilmstripHandoff {
    static var duration: TimeInterval { Chrome.Motion.duration(0.21) }
    static let timing = CAMediaTimingFunction(controlPoints: 0.24, 0.72, 0.24, 1)
    static let opacityKey = "filmstrip-handoff-opacity"

    static func animateWidth(of layer: CALayer, from start: CGFloat, to end: CGFloat, duration: TimeInterval) {
        guard abs(end - start) > 1 else { return }
        let mask = CAGradientLayer()
        mask.startPoint = CGPoint(x: 0, y: 0.5)
        mask.endPoint = CGPoint(x: 1, y: 0.5)
        mask.colors = [NSColor.clear.cgColor, NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
        mask.locations = [0, 0.015, 0.985, 1]
        mask.frame = layer.bounds
        mask.bounds.size.width = end
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if end >= layer.bounds.width {
            CATransaction.setCompletionBlock {
                if layer.mask === mask { layer.mask = nil }
            }
        }
        layer.mask = mask
        let animation = CABasicAnimation(keyPath: "bounds.size.width")
        animation.fromValue = start
        animation.toValue = end
        animation.duration = duration
        animation.timingFunction = timing
        mask.add(animation, forKey: "filmstrip-handoff-width")
        CATransaction.commit()
    }

    static func reveal(_ layer: CALayer?, from opacity: Float, duration: TimeInterval) {
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = opacity
        animation.toValue = 1
        animation.duration = duration
        animation.timingFunction = timing
        layer?.add(animation, forKey: opacityKey)
    }
}
