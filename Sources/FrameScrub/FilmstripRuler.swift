import AppKit
import FrameScrubCore

/// A small ruler around the playhead, on the same projection as a seek.
@MainActor enum FilmstripRuler {
    struct Mark {
        let delta: Double
        let offset: Double
    }

    private static let style: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium),
        .foregroundColor: NSColor(white: 1, alpha: 0.94)
    ]

    static func marks(in projection: TimelineProjection, around time: Double) -> [Mark] {
        let aim = 90.0
        let rate = projection.secondsPerPoint
        guard rate.isFinite, rate > 0, projection.halfWidth >= 55 else { return [] }
        let decade = pow(10, floor(log10(max(0.1, aim * rate))))
        let head = projection.offset(for: time)
        var best: [Mark] = []
        var bestError = Double.infinity
        for multiple in [0.5, 1.0, 2.0, 5.0, 10.0] {
            let interval = decade * multiple
            guard interval >= 0.1 else { continue }
            var marks: [Mark] = []
            var error = 0.0
            for delta in [-interval, interval] {
                let target = time + delta
                guard target >= 0, target <= projection.duration else { continue }
                let offset = projection.offset(for: target)
                let distance = abs(offset - head)
                guard abs(offset) <= projection.halfWidth - 24, (44...160).contains(distance) else { continue }
                marks.append(Mark(delta: delta, offset: offset))
                error += abs(distance - aim)
            }
            if marks.count > best.count || (marks.count == best.count && error < bestError) {
                best = marks
                bestError = error
            }
        }
        return best
    }

    static func draw(in film: NSRect, projection: TimelineProjection, around time: Double, avoiding markers: [NSRect]) {
        guard film.height >= 33 else { return }
        for mark in marks(in: projection, around: time) {
            let sign = mark.delta < 0 ? "−" : "+"
            let text = NSAttributedString(string: sign + TimelinePositionText.interval(abs(mark.delta)), attributes: style)
            let size = text.size()
            let x = (film.midX + mark.offset).rounded()
            let label = NSRect(x: x - size.width / 2, y: film.maxY - 6 - size.height,
                               width: size.width, height: size.height)
            let plate = label.insetBy(dx: -4, dy: -0.5)
            guard plate.minX >= film.minX, plate.maxX <= film.maxX,
                  !markers.contains(where: { $0.intersects(plate.insetBy(dx: -3, dy: 0)) }) else { continue }
            NSColor(white: 0.08, alpha: 0.9).setFill()
            NSRect(x: x - 1, y: plate.maxY, width: 2, height: film.maxY - plate.maxY).fill()
            NSColor(white: 1, alpha: 0.85).setFill()
            NSRect(x: x - 0.5, y: plate.maxY, width: 1, height: film.maxY - plate.maxY).fill()
            TimelineGlass.drawChip(in: plate, radius: 3)
            text.draw(at: label.origin)
        }
    }
}
