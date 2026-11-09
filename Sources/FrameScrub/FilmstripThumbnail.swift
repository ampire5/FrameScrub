import AppKit
import FrameScrubCore

/// Draws the video frame inside a filmstrip cell.
enum FilmstripThumbnail {
    static func fittedRect(aspect: CGFloat, in bounds: NSRect) -> NSRect {
        guard aspect.isFinite, aspect > 0, bounds.width > 0, bounds.height > 0 else { return .zero }
        let width = min(bounds.width, bounds.height * aspect)
        let height = width / aspect
        return NSRect(x: bounds.midX - width / 2, y: bounds.midY - height / 2, width: width, height: height)
    }

    static func draw(_ image: NSImage, geometry: DisplayGeometry, in bounds: NSRect, opacity: CGFloat,
                     cropToFill: Bool = false, cropAmount: Double = 1) {
        let crop = geometry.crop
        var source = NSRect(x: image.size.width * crop.minX, y: image.size.height * crop.minY,
                            width: image.size.width * crop.width, height: image.size.height * crop.height)
        guard source.height > 0 else { return }
        if cropToFill, bounds.height > 0, geometry.pixelAspect > 0 {
            let shownWidth = source.height * bounds.width / bounds.height / geometry.pixelAspect
            if shownWidth < source.width {
                let removed = (source.width - shownWidth) * min(1, max(0, cropAmount))
                source.origin.x += removed / 2
                source.size.width -= removed
            }
        }
        let target = fittedRect(aspect: source.width / source.height * geometry.pixelAspect, in: bounds)
        image.draw(in: target, from: source, operation: .sourceOver, fraction: opacity)
    }
}
