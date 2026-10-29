import Foundation

/// A reversible time scale, linear near the playhead and exponentially compressed towards the file's ends.
/// Capture one value on pointer-down: moving that value's coordinates never changes the scale under the finger.
public struct TimelineLens: Sendable {
    public let duration: Double
    public let center: Double
    public let halfWidth: Double
    public let secondsPerPoint: Double
    private let localWidth: Double
    private let leftRate: Double
    private let rightRate: Double

    public init(duration: Double, center: Double, halfWidth: Double, secondsPerPoint: Double, focusFraction: Double = 0.3) {
        let duration = duration.isFinite ? max(0, duration) : 0
        self.duration = duration
        self.center = center.isFinite ? min(max(0, center), duration) : 0
        self.halfWidth = halfWidth.isFinite ? max(1, halfWidth) : 1
        self.secondsPerPoint = secondsPerPoint.isFinite && secondsPerPoint > 0 ? secondsPerPoint : 1.0 / 60
        let fraction = focusFraction.isFinite ? min(0.75, max(0.08, focusFraction)) : 0.3
        localWidth = min(self.halfWidth, max(1, self.halfWidth * fraction))
        // Use locals: all stored properties must be initialized before accessing self in a closure.
        let width = self.halfWidth, step = self.secondsPerPoint, local = localWidth
        func solve(_ room: Double) -> Double {
            guard room > width * step, width > local else { return 0 }
            var lo = 0.0, hi = 80 / width
            for _ in 0..<48 {
                let k = (lo + hi) / 2
                if step * (local + expm1(k * (width - local)) / k) < room { lo = k } else { hi = k }
            }
            return (lo + hi) / 2
        }
        leftRate = solve(self.center)
        rightRate = solve(duration - self.center)
    }

    public func unclampedTime(at offset: Double) -> Double {
        guard offset.isFinite else { return center }
        let distance = abs(offset), rate = offset < 0 ? leftRate : rightRate
        let seconds = distance <= localWidth || rate == 0 ? distance * secondsPerPoint
            : secondsPerPoint * (localWidth + expm1(min(700, rate * (distance - localWidth))) / rate)
        return center + (offset < 0 ? -seconds : seconds)
    }

    public func time(at offset: Double) -> Double { min(duration, max(0, unclampedTime(at: offset))) }

    /// Local seconds per point, used to give dense regions narrower, centre-cropped pictures.
    public func density(at offset: Double) -> Double {
        guard offset.isFinite else { return secondsPerPoint }
        let rate = offset < 0 ? leftRate : rightRate
        return secondsPerPoint * exp(min(700, rate * max(0, abs(offset) - localWidth)))
    }

    /// A visible cell may lie on an endpoint up to the solver's roundoff. Real overscroll stays empty.
    public func visibleTime(at offset: Double) -> Double? {
        let value = unclampedTime(at: offset)
        let tolerance = max(1, duration) * 1e-10
        guard value >= -tolerance, value <= duration + tolerance else { return nil }
        return min(duration, max(0, value))
    }

    public func offset(for time: Double) -> Double {
        guard time.isFinite else { return 0 }
        let delta = min(duration, max(0, time)) - center
        let seconds = abs(delta), rate = delta < 0 ? leftRate : rightRate
        let offset = seconds <= localWidth * secondsPerPoint || rate == 0 ? seconds / secondsPerPoint
            : localWidth + log1p(rate * (seconds / secondsPerPoint - localWidth)) / rate
        return delta < 0 ? -offset : offset
    }
}
