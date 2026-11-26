import AppKit

/// The current-position marker shared by the full and mini filmstrips.
@MainActor enum FilmstripPlayhead {
    static let accent = NSColor(srgbRed: 0.46, green: 0.85, blue: 1, alpha: 1)
    static let width: CGFloat = 10
    static let topExtension: CGFloat = 3

    static func draw(x: CGFloat, bottom: CGFloat, top: CGFloat) {
        guard top > bottom else { return }
        let capHalfWidth = width / 2 - 1
        let capTop = top + topExtension - 1
        let marker = NSBezierPath()
        marker.move(to: NSPoint(x: x - capHalfWidth, y: capTop))
        marker.line(to: NSPoint(x: x + capHalfWidth, y: capTop))
        marker.line(to: NSPoint(x: x + 1, y: top - 3))
        marker.line(to: NSPoint(x: x + 1, y: bottom + 1))
        marker.line(to: NSPoint(x: x - 1, y: bottom + 1))
        marker.line(to: NSPoint(x: x - 1, y: top - 3))
        marker.close()
        marker.lineWidth = 2
        marker.lineJoinStyle = .round
        NSColor(white: 0.08, alpha: 1).setStroke()
        marker.stroke()
        accent.setFill()
        marker.fill()
    }
}
