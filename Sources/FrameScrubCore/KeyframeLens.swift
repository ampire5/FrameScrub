import Foundation

/// The keyframes around a frame pointed at on the seek bar: a magnified stretch of the file shown under the preview,
/// where keyframes a few seconds apart are far enough apart to see (on the bar itself they merge on long files).
public struct KeyframeLens: Equatable, Sendable {
    /// Frames the lens spans: `spanSeconds` either side of `frame`, cut to the file.
    public let range: ClosedRange<Int>
    /// Keyframes inside `range`, in order.
    public let keyframes: [Int]
    public let frame: Int
    /// "K" on a keyframe, else the distance to the keyframes either side: "K −0.80 s / +2.20 s".
    public let label: String

    /// Nil when the index knows no keyframes (an approximate index, before the exact one is in).
    public init?(index: FrameIndex, frame: Int, spanSeconds: Double = 20) {
        guard index.isExact, index.frameCount > 0 else { return nil }
        let last = index.frameCount - 1
        let frame = min(max(frame, 0), last)
        let seconds = index.seconds(forFrame: frame)
        range = max(index.frameNumber(forSeconds: seconds - spanSeconds), 0)...min(index.frameNumber(forSeconds: seconds + spanSeconds), last)
        var keyframes: [Int] = []
        var next: Int? = index.keyframe(atOrBefore: range.lowerBound)
        if let first = next, first < range.lowerBound { next = index.keyframe(after: first) }
        while let keyframe = next, keyframe <= range.upperBound {
            keyframes.append(keyframe)
            next = index.keyframe(after: keyframe)
        }
        self.keyframes = keyframes
        self.frame = frame
        let before = index.keyframe(atOrBefore: frame)
        if before == frame {
            label = "K"
        } else {
            func distance(_ keyframe: Int) -> String {
                String(format: "%.2f s", abs(index.seconds(forFrame: keyframe) - seconds))
            }
            label = "K −" + distance(before) + (index.keyframe(after: frame).map { " / +" + distance($0) } ?? "")
        }
    }

    /// The keyframe `steps` keyframes away from the one the preview of `frame` shows (the keyframe at or before it),
    /// stopping at the first and last keyframes. Nil without an exact index.
    public static func step(_ index: FrameIndex, from frame: Int, by steps: Int) -> Int? {
        guard index.isExact, index.frameCount > 0 else { return nil }
        var keyframe = index.keyframe(atOrBefore: frame)
        for _ in 0..<abs(steps) {
            if steps > 0 {
                guard let next = index.keyframe(after: keyframe) else { break }
                keyframe = next
            } else {
                guard keyframe > 0 else { break }
                keyframe = index.keyframe(atOrBefore: keyframe - 1)
            }
        }
        return keyframe
    }
}

/// Scrolls over the seek bar turned into keyframe steps of its preview: one per wheel notch, one per
/// `GestureRouter.stepPoints` of trackpad travel on the dominant axis. Forward is wheel up, or a horizontal swipe
/// the way it scrubs forward (`invertX` = `scrub-invert`). Momentum is ignored, so a flick does not run away.
public struct LensScroll: Sendable {
    public var invertX: Bool
    private var travel = 0.0

    public init(invertX: Bool = false) { self.invertX = invertX }

    public mutating func steps(for s: ScrollSample) -> Int {
        if s.began { travel = 0 }
        guard !s.momentum else { return 0 }
        let forward = abs(s.deltaX) > abs(s.deltaY) ? (invertX ? s.deltaX : -s.deltaX) : s.deltaY
        guard forward != 0 else { return 0 }
        guard s.precise else { return forward > 0 ? 1 : -1 }
        if (forward > 0) != (travel > 0), travel != 0 { travel = 0 }
        travel += forward
        let steps = Int(travel / GestureRouter.stepPoints)
        travel -= Double(steps) * GestureRouter.stepPoints
        return steps
    }
}
