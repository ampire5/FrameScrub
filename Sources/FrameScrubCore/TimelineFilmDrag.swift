import Foundation
import CoreGraphics

/// Drag in the projection captured at mouse-down. Clamp the logical offset and keep resistance visual.
public struct TimelineFilmDrag: Sendable {
    private let lens: TimelineProjection
    private let bounds: ClosedRange<Double>
    private var offset: Double
    private var pointer: Double
    private var lastTimestamp: Double
    private var overshoot = 0.0
    private var velocity = DragVelocityTracker()
    private var lastDirection = 0.0
    private let marks: [(offset: Double, seconds: Double)]
    private let precisionGain: Double
    private var snappedMark: Int?
    private var passedMark: Int?
    public private(set) var hasMoved: Bool

    public init(lens: TimelineProjection, lastFrameSeconds: Double, pointer: Double,
                timestamp: Double, caught: Bool = false, markSeconds: [Double] = [], frameSeconds: Double? = nil) {
        self.lens = lens
        bounds = lens.offset(for: 0)...lens.offset(for: lastFrameSeconds)
        offset = min(bounds.upperBound, max(bounds.lowerBound, lens.focusOffset))
        self.pointer = pointer
        lastTimestamp = timestamp
        marks = markSeconds.map { (lens.offset(for: $0), $0) }.sorted { $0.0 < $1.0 }
        precisionGain = frameSeconds.map { min(0.35, max(0.000001, $0 / (lens.secondsPerPoint * 3))) } ?? 0.35
        hasMoved = caught
        velocity.add(CGPoint(x: offset, y: 0), at: timestamp)
    }

    public var seconds: Double { snappedMark.map { marks[$0].seconds } ?? lens.time(at: offset) }
    public var stretch: Double {
        if let snappedMark { return RubberBand.offset(raw: marks[snappedMark].offset - offset, dimension: 5) }
        return RubberBand.offset(raw: -overshoot, dimension: 10)
    }

    public mutating func move(to x: Double, at timestamp: Double, precision: Bool = true) {
        let delta = pointer - x
        guard hasMoved || abs(delta) > 6 else { return }
        hasMoved = true
        pointer = x
        let speed = abs(delta) / max(0.008, timestamp - lastTimestamp)
        lastTimestamp = timestamp
        guard delta != 0 else { return }
        let direction = delta.sign == .minus ? -1.0 : 1.0
        let reversed = lastDirection != 0 && lastDirection != direction
        if lastDirection != direction { velocity.reset(); overshoot = 0 }
        lastDirection = direction
        if let snappedMark, reversed || !precision {
            offset = marks[snappedMark].offset
            passedMark = snappedMark
            self.snappedMark = nil
        }
        let fast = min(1, max(0, (speed - 70) / 500))
        let gain = precision ? precisionGain + (1.5 - precisionGain) * fast * fast : 1
        let previousOffset = offset
        let desired = offset + delta * gain
        offset = min(bounds.upperBound, max(bounds.lowerBound, desired))
        if offset == desired { overshoot = 0 } else { overshoot += desired - offset }
        updateDetent(slow: precision && speed <= 180, reversed: reversed, previousOffset: previousOffset)
        velocity.add(CGPoint(x: offset, y: 0), at: timestamp)
    }

    private mutating func updateDetent(slow: Bool, reversed: Bool, previousOffset: Double) {
        let captureRadius = 4 * precisionGain
        let releaseRadius = 9 * precisionGain
        if let snappedMark {
            if slow, !reversed, abs(marks[snappedMark].offset - offset) < releaseRadius { return }
            passedMark = snappedMark
            self.snappedMark = nil
            return
        }
        if let passedMark, abs(marks[passedMark].offset - offset) > releaseRadius { self.passedMark = nil }
        guard slow, !reversed, overshoot == 0 else { return }
        var low = 0
        var high = marks.count
        while low < high {
            let middle = (low + high) / 2
            if marks[middle].offset < offset { low = middle + 1 } else { high = middle }
        }
        let nearest = [low - 1, low].filter {
            marks.indices.contains($0) && $0 != passedMark && (marks[$0].offset - previousOffset) * lastDirection > 1e-8
        }.min {
            abs(marks[$0].offset - offset) < abs(marks[$1].offset - offset)
        }
        if let nearest, abs(marks[nearest].offset - offset) <= captureRadius { snappedMark = nearest }
    }

    public func release(at timestamp: Double, duration: Double = Coast.defaultDuration) -> Coast? {
        let speed = Double(velocity.releaseVelocity(at: timestamp).dx)
        guard abs(speed) >= 160, overshoot == 0, snappedMark == nil else { return nil }
        let cap = lens.halfWidth * 0.36
        let travel = min(cap, max(-cap, speed * duration / 3))
        let destination = min(bounds.upperBound, max(bounds.lowerBound, offset + travel))
        guard abs(destination - offset) >= 2 else { return nil }
        return Coast(duration: duration, lens: lens, origin: offset, destination: destination)
    }

    public struct Coast: Sendable {
        public static let defaultDuration = 0.22
        public let duration: Double
        fileprivate let lens: TimelineProjection
        fileprivate let origin: Double
        fileprivate let destination: Double

        public func seconds(at elapsed: Double) -> Double {
            let remaining = 1 - min(1, max(0, elapsed / duration))
            return lens.time(at: destination + (origin - destination) * remaining * remaining * remaining)
        }
    }
}
