import AppKit
import FrameScrubCore

/// Draws the video frame inside a filmstrip cell.
enum FilmstripThumbnail {
    static func drawBackground(in bounds: NSRect) {
        NSColor(white: 1, alpha: 0.06).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 3, yRadius: 3).fill()
    }

    static func fittedRect(aspect: CGFloat, in bounds: NSRect) -> NSRect {
        guard aspect.isFinite, aspect > 0, bounds.width > 0, bounds.height > 0 else { return .zero }
        let width = min(bounds.width, bounds.height * aspect)
        let height = width / aspect
        return NSRect(x: bounds.midX - width / 2, y: bounds.midY - height / 2, width: width, height: height)
    }

    static func draw(_ image: NSImage, geometry: DisplayGeometry, in bounds: NSRect, opacity: CGFloat,
                     cropSides: Bool = false, cropAmount: Double = 1, stretch: Double = 0) {
        let crop = geometry.crop
        var source = NSRect(x: image.size.width * crop.minX, y: image.size.height * crop.minY,
                            width: image.size.width * crop.width, height: image.size.height * crop.height)
        guard source.height > 0 else { return }
        if cropSides, bounds.height > 0, geometry.pixelAspect > 0 {
            let shownWidth = source.height * bounds.width / bounds.height / geometry.pixelAspect
            let strength = min(1, max(0, cropAmount))
            if shownWidth < source.width {
                let removed = (source.width - shownWidth) * strength
                source.origin.x += removed / 2
                source.size.width -= removed
            }
        }
        let fitted = fittedRect(aspect: source.width / source.height * geometry.pixelAspect, in: bounds)
        guard !fitted.isEmpty else { return }
        let amount = min(1, max(0, stretch))
        let target = fitted.insetBy(dx: -amount * (bounds.width - fitted.width) / 2,
                                    dy: -amount * (bounds.height - fitted.height) / 2)
        image.draw(in: target, from: source, operation: .sourceOver, fraction: opacity)
    }
}
