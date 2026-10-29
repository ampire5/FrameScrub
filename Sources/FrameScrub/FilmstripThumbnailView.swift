import AppKit
import FrameScrubCore

/// Cached hover enlargement. It never decodes, resizes the strip or intercepts input.
final class FilmstripThumbnailView: NSView {
    var image: NSImage?
    var geometry = DisplayGeometry.identity
    var time = ""
    var seconds = 0.0

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

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

    override func draw(_ dirtyRect: NSRect) {
        let plate = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 5, yRadius: 5)
        NSColor(white: 0.04, alpha: 0.98).setFill(); plate.fill()
        NSGraphicsContext.saveGraphicsState()
        plate.addClip()
        if let image { Self.draw(image, geometry: geometry, in: bounds.insetBy(dx: 3, dy: 3), opacity: 1) }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white, .backgroundColor: NSColor.black.withAlphaComponent(0.75)]
        let label = time as NSString
        label.draw(at: NSPoint(x: bounds.midX - label.size(withAttributes: attributes).width / 2, y: 6), withAttributes: attributes)
        NSGraphicsContext.restoreGraphicsState()
        NSColor.white.withAlphaComponent(0.8).setStroke(); plate.lineWidth = 1; plate.stroke()
    }
}
