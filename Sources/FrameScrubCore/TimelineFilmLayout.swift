import Foundation

/// Fixed samples projected through a moving magnifier, or a fixed central magnifier over an absolute time grid.
public struct TimelineFilmLayout: Sendable {
    public static let maximumCells = 65
    public struct Cell: Sendable {
        public let id: Int64
        public let offset: Double
        public let width: Double
        public let seconds: Double?
        public let cropped: Bool
        public let cropAmount: Double
    }
    public let mode: TimelineFilmMode
    public let lens: TimelineProjection
    public let fullWidth: Double
    public let cells: [Cell]
    public var playheadOffset: Double { lens.focusOffset }

    public init(width: Double, height: Double, aspect: Double, duration: Double, center: Double,
                secondsPerThumbnail: Double, focusFraction: Double, cropStrength: Double, mode: TimelineFilmMode = .lens,
                magnification: Double = 2.75, outsideDensity: Double = 2.75) {
        let width = width.isFinite ? max(0, width) : 0
        let height = height.isFinite && height > 0 ? height : 48
        let aspect = aspect.isFinite && aspect > 0 ? aspect : 16.0 / 9
        let duration = duration.isFinite ? max(0, duration) : 0
        let center = center.isFinite ? min(duration, max(0, center)) : 0
        let crop = cropStrength.isFinite ? min(1, max(0, cropStrength)) : 0.7
        let seconds = secondsPerThumbnail.isFinite ? min(30, max(0.1, secondsPerThumbnail)) : 1
        let focus = focusFraction.isFinite ? min(0.75, max(0.08, focusFraction)) : 0.3
        let magnification = magnification.isFinite ? min(3.8, max(1, magnification)) : 2.75
        let density = outsideDensity.isFinite ? min(4, max(0.5, outsideDensity)) : 2.75
        self.mode = mode
        fullWidth = min(width, max(1, height * aspect + 2))
        let wanted = max(1, fullWidth / density)
        let count = min(Self.maximumCells, max(3, Int(ceil(min(Double(Self.maximumCells), width / wanted)))))
        let base = mode == .segment ? max(width / Double(Self.maximumCells - 2), wanted) : width / Double(count)
        lens = TimelineProjection(mode: mode, duration: duration, center: center, width: width, baseWidth: base,
            interval: seconds, magnification: magnification, focusFraction: focus)
        guard width > 0, duration > 0 else { cells = []; return }
        let projection = lens, full = fullWidth
        func cell(_ id: Int64, left: Double, right: Double, time: Double?) -> Cell? {
            let l = projection.position(forBaseline: max(-width / 2, left))
            let r = projection.position(forBaseline: min(width / 2, right))
            guard r - l > 1e-9 else { return nil }
            return Cell(id: id, offset: (l + r) / 2, width: r - l, seconds: time,
                        cropped: crop > 0 && r - l < full - 0.5, cropAmount: crop)
        }
        var result: [Cell] = []
        if mode == .segment {
            let phase = center / seconds
            let first = Int64(min(Double(Int64.max / 4), max(0, floor(phase)))) - Int64(Self.maximumCells)
            // At most 63 baseline cells cross the viewport, plus its two partial edge cells.
            let start = max(first, Int64(min(Double(Int64.max / 4), max(Double(Int64.min / 4),
                floor(phase - width / 2 / max(1e-9, base) - 0.5)))))
            for step in 0..<(Self.maximumCells + 2) {
                let id = start + Int64(step)
                let x = (Double(id) - phase) * base
                if x - base / 2 >= width / 2 { break }
                guard x + base / 2 > -width / 2 else { continue }
                let time = Double(id) * seconds
                if let value = cell(id, left: x - base / 2, right: x + base / 2,
                    time: time >= 0 && time <= duration ? time : nil) { result.append(value) }
            }
        } else {
            for i in 0..<count {
                if let value = cell(Int64(i), left: -width / 2 + Double(i) * base,
                    right: -width / 2 + Double(i + 1) * base, time: Double(i) / Double(count - 1) * duration) {
                    result.append(value)
                }
            }
        }
        cells = result
    }
    public func cell(at offset: Double) -> Cell? {
        guard offset.isFinite else { return nil }
        return cells.first { offset >= $0.offset - $0.width / 2 && offset <= $0.offset + $0.width / 2 }
    }
    /// Mouse-wheel navigation follows the painted, loaded cells, not the video's keyframe index.
    public func stepSample(from time: Double, by steps: Int, available: Set<Double>, tolerance: Double = 0) -> Double? {
        guard time.isFinite, steps != 0 else { return nil }
        let times = cells.compactMap(\.seconds).filter { available.contains($0) }
        guard !times.isEmpty else { return nil }
        let epsilon = max(1, abs(time)) * 1e-10
        let tolerance = tolerance.isFinite ? max(0, tolerance) : 0
        let nearest = times.min { abs($0 - time) < abs($1 - time) }!
        let anchor = abs(nearest - time) <= tolerance + epsilon ? nearest : time
        if steps > 0 {
            guard let i = times.firstIndex(where: { $0 > anchor + epsilon }) else { return nil }
            return times[min(times.count - 1, i + min(times.count - 1, steps - 1))]
        }
        guard let i = times.lastIndex(where: { $0 < anchor - epsilon }) else { return nil }
        let distance = steps == Int.min ? times.count : min(times.count, -steps)
        return times[max(0, i - (distance - 1))]
    }
}
