import AppKit

/// Keeps the current time anchored while the surrounding details come and go.
@MainActor struct FilmstripReadout {
    static let timeStyle: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.white
    ]
    private static let currentStyle: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.white
    ]
    private static let durationStyle: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium),
        .foregroundColor: NSColor(white: 1, alpha: 0.90)
    ]
    private static let frameStyle: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium),
        .foregroundColor: NSColor(white: 1, alpha: 0.85)
    ]
    private static let travelStyle: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium), .foregroundColor: NSColor.systemCyan
    ]
    private static let padding: CGFloat = 5
    private static let gap: CGFloat = 8

    private let current: NSAttributedString
    private let duration: NSAttributedString?
    private let durationRect: NSRect
    let currentRect: NSRect
    let timeRect: NSRect

    init?(time seconds: Double, duration: Double, anchor: CGFloat, in row: NSRect) {
        let inner = row.insetBy(dx: Self.padding, dy: 0)
        let current = NSAttributedString(string: TimelinePositionText.clock(seconds), attributes: Self.currentStyle)
        let size = current.size()
        guard size.width <= inner.width else { return nil }
        let x = min(inner.maxX - size.width, max(inner.minX, anchor - size.width / 2))
        self.current = current
        currentRect = NSRect(x: x, y: row.minY, width: size.width, height: size.height)
        let total = NSAttributedString(string: "/ \(TimelinePositionText.clock(duration, tenths: duration < 1))",
                                       attributes: Self.durationStyle)
        let suffix = NSRect(origin: NSPoint(x: currentRect.maxX + 4, y: row.minY + 1), size: total.size())
        self.duration = suffix.maxX <= inner.maxX ? total : nil
        durationRect = suffix
        timeRect = self.duration == nil ? currentRect : currentRect.union(suffix)
    }

    func draw(in row: NSRect, frames: [String], journey: NavigationJourney?, avoiding hover: NSRect? = nil) {
        let left = hover.map { $0.maxX <= timeRect.minX ? $0.maxX + Self.padding : row.minX } ?? row.minX
        let right = hover.map { $0.minX >= timeRect.maxX ? $0.minX - Self.padding : row.maxX } ?? row.maxX
        let frame = firstFitting(frames, style: Self.frameStyle,
                                 width: timeRect.minX - Self.gap - left - Self.padding)
        let travel = [journey?.frameDisplacement, journey?.displacement].compactMap { $0 }
        let delta = firstFitting([travel.joined(separator: " · ")] + travel, style: Self.travelStyle,
                                 width: right - Self.padding - timeRect.maxX - Self.gap)
        let frameX = frame.map { timeRect.minX - Self.gap - $0.size().width } ?? timeRect.minX
        let deltaEnd = delta.map { timeRect.maxX + Self.gap + $0.size().width } ?? timeRect.maxX
        let plate = NSRect(x: frameX, y: timeRect.minY, width: deltaEnd - frameX, height: timeRect.height)
        TimelineGlass.drawChip(in: plate.insetBy(dx: -Self.padding, dy: -1))
        current.draw(at: currentRect.origin)
        duration?.draw(at: durationRect.origin)
        frame?.draw(at: NSPoint(x: frameX, y: timeRect.minY + 0.5))
        delta?.draw(at: NSPoint(x: timeRect.maxX + Self.gap, y: timeRect.minY + 0.5))
    }

    private func firstFitting(_ options: [String], style: [NSAttributedString.Key: Any], width: CGFloat) -> NSAttributedString? {
        options.lazy.filter { !$0.isEmpty }.map { NSAttributedString(string: $0, attributes: style) }
            .first { $0.size().width <= width }
    }
}
