import AppKit
import HomeChrome

/// A passive glass surface. The owner's timeline still receives pointer events.
final class TimelineGlass: NSVisualEffectView {
    init(radius: CGFloat) {
        super.init(frame: .zero)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        Chrome.Palette.overMedia.apply(to: self)
        wantsLayer = true
        layer?.cornerRadius = radius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5
        layer?.borderColor = Chrome.Palette.overMedia.rim.cgColor

        let veil = NSView(frame: bounds)
        veil.wantsLayer = true
        veil.layer?.backgroundColor = Chrome.Palette.overMedia.glassTint.withAlphaComponent(0.30).cgColor
        veil.autoresizingMask = [.width, .height]
        addSubview(veil)
        setAccessibilityHidden(true)
    }

    required init?(coder: NSCoder) { fatalError("not used") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    static func drawChip(in rect: NSRect, radius: CGFloat = 4) {
        let shape = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        NSColor(srgbRed: 44 / 255, green: 44 / 255, blue: 48 / 255, alpha: 0.72).setFill()
        shape.fill()
        Chrome.Palette.overMedia.rim.setStroke()
        shape.lineWidth = 0.5
        shape.stroke()
    }
}

/// Draws above the backdrop while leaving hit testing and accessibility with the timeline.
final class TimelineInk: NSView {
    var paint: (() -> Void)?

    override func draw(_ dirtyRect: NSRect) { paint?() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
