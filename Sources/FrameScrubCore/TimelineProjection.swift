import Foundation

public enum TimelineFilmMode: Int, CaseIterable, Sendable {
    case lens, segment, overview
    public var title: String {
        switch self { case .lens: return "Whole File Lens"; case .segment: return "Segment"; case .overview: return "Whole File" }
    }
}

/// Smooth positive magnification, normalised to the viewport with one uniform outside density.
/// Sample identities are independent of this projection and never follow the playhead.
public struct TimelineProjection: Sendable {
    public let mode: TimelineFilmMode
    public let duration: Double
    public let center: Double
    public let halfWidth: Double
    public let secondsPerPoint: Double
    public var focusOffset: Double { mode == .segment ? 0 : position(forBaseline: baselineFocus) }
    public let magnification: Double
    private let baseWidth: Double
    private let interval: Double
    private let radius: Double
    private let strength: Double
    private let baselineFocus: Double
    private let lowerPrimitive: Double
    private let scaleFactor: Double
    private let leftSlope: Double
    private let rightSlope: Double

    init(mode: TimelineFilmMode, duration: Double, center: Double, width: Double, baseWidth: Double,
         interval: Double, magnification: Double, focusFraction: Double) {
        self.mode = mode; self.duration = duration; self.center = center
        halfWidth = width / 2; self.baseWidth = max(1e-9, baseWidth); self.interval = interval
        let focus = mode == .segment ? 0 : -width / 2 + baseWidth / 2 +
            (duration > 0 ? center / duration : 0) * (width - baseWidth)
        baselineFocus = focus
        let radius = max(1, width * focusFraction / 2)
        self.radius = radius
        self.magnification = mode == .overview ? 1 : magnification
        let strength = self.magnification - 1
        self.strength = strength
        let lower = -width / 2 + strength * Self.integral(-width / 2 - focus, radius: radius)
        let upper = width / 2 + strength * Self.integral(width / 2 - focus, radius: radius)
        lowerPrimitive = lower
        let scale = width > 0 ? width / max(1e-9, upper - lower) : 1
        scaleFactor = scale
        leftSlope = scale * (1 + strength * Self.bump(-width / 2 - focus, radius: radius))
        rightSlope = scale * (1 + strength * Self.bump(width / 2 - focus, radius: radius))
        let rate = mode == .segment ? interval / max(1e-9, baseWidth) : duration / max(1e-9, width - baseWidth)
        secondsPerPoint = rate / (scale * (1 + strength))
    }

    private static func bump(_ x: Double, radius: Double) -> Double {
        abs(x) < radius ? 0.5 * (1 + cos(.pi * x / radius)) : 0
    }
    private static func integral(_ x: Double, radius: Double) -> Double {
        if abs(x) >= radius { return x < 0 ? -radius / 2 : radius / 2 }
        return x / 2 + radius / (2 * .pi) * sin(.pi * x / radius)
    }
    /// Derivative falls smoothly from the central peak to the outside level, never below it.
    public func position(forBaseline x: Double) -> Double {
        guard strength > 0 else { return x }
        if x <= -halfWidth { return -halfWidth + (x + halfWidth) * leftSlope }
        if x >= halfWidth { return halfWidth + (x - halfWidth) * rightSlope }
        return -halfWidth + (x + strength * Self.integral(x - baselineFocus, radius: radius) - lowerPrimitive) * scaleFactor
    }
    private func baseline(at offset: Double) -> Double {
        guard strength > 0 else { return offset }
        if offset <= -halfWidth { return -halfWidth + (offset + halfWidth) / leftSlope }
        if offset >= halfWidth { return halfWidth + (offset - halfWidth) / rightSlope }
        var lo = -halfWidth, hi = halfWidth
        for _ in 0..<44 {
            let mid = (lo + hi) / 2
            if position(forBaseline: mid) < offset { lo = mid } else { hi = mid }
        }
        return (lo + hi) / 2
    }
    public func time(at offset: Double) -> Double {
        guard offset.isFinite else { return center }
        let x = baseline(at: offset)
        let time = mode == .segment ? center + x / baseWidth * interval
            : (x + halfWidth - baseWidth / 2) / max(1e-9, 2 * halfWidth - baseWidth) * duration
        return min(duration, max(0, time))
    }
    public func offset(for time: Double) -> Double {
        let time = time.isFinite ? min(duration, max(0, time)) : center
        let x = mode == .segment ? (time - center) / interval * baseWidth
            : -halfWidth + baseWidth / 2 + (duration > 0 ? time / duration : 0) * (2 * halfWidth - baseWidth)
        return position(forBaseline: x)
    }
}
