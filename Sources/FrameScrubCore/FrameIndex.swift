import Foundation

/// Maps presentation timestamps (video stream time-base units) to 0-based frame numbers.
/// An exact index comes from a full demuxer scan; an approximate one assumes a constant
/// frame rate and is used until the scan finishes. Seconds are measured from `zeroPTS`.
public struct FrameIndex: Sendable {
    public let timeBase: Double
    public let zeroPTS: Int64
    public let frameCount: Int
    public let isExact: Bool
    private let ptsList: [Int64]
    private let keyframeList: [Int]
    private let ticksPerFrame: Double

    public init(pts: [Int64], keyframePTS: Set<Int64>, timeBase: Double, zeroPTS: Int64? = nil) {
        let sorted = Array(Set(pts)).sorted()
        var keys = sorted.indices.filter { keyframePTS.contains(sorted[$0]) }
        if keys.first != 0 { keys.insert(0, at: 0) }
        ptsList = sorted
        keyframeList = keys
        self.timeBase = timeBase
        self.zeroPTS = zeroPTS ?? sorted.first ?? 0
        frameCount = sorted.count
        isExact = true
        ticksPerFrame = 0
    }

    private init(startPTS: Int64, ticksPerFrame: Double, frameCount: Int, timeBase: Double) {
        ptsList = []
        keyframeList = [0]
        self.timeBase = timeBase
        zeroPTS = startPTS
        self.frameCount = frameCount
        isExact = false
        self.ticksPerFrame = ticksPerFrame
    }

    public static func approximate(startPTS: Int64, ticksPerFrame: Double, frameCount: Int,
                                   timeBase: Double) -> FrameIndex {
        FrameIndex(startPTS: startPTS, ticksPerFrame: ticksPerFrame, frameCount: frameCount, timeBase: timeBase)
    }

    public var keyframes: [Int] { keyframeList }

    public func pts(forFrame n: Int) -> Int64 {
        guard frameCount > 0 else { return zeroPTS }
        let n = clamp(n)
        if isExact { return ptsList[n] }
        return zeroPTS + Int64((Double(n) * ticksPerFrame).rounded())
    }

    /// The last frame whose pts is <= `pts` (clamped to the valid range).
    public func frameNumber(forPTS pts: Int64) -> Int {
        guard frameCount > 0 else { return 0 }
        guard isExact else {
            return clamp(Int(((Double(pts - zeroPTS) + 0.5) / ticksPerFrame).rounded(.down)))
        }
        if pts < ptsList[0] { return 0 }
        var lo = 0, hi = ptsList.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if ptsList[mid] <= pts { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    /// The frame whose pts is closest to `pts` (ties go to the earlier frame).
    public func nearestFrameNumber(forPTS pts: Int64) -> Int {
        let lower = frameNumber(forPTS: pts)
        guard lower + 1 < frameCount else { return lower }
        return self.pts(forFrame: lower + 1) - pts < pts - self.pts(forFrame: lower) ? lower + 1 : lower
    }

    /// The keyframe to start decoding from to reach frame `n`. Approximate indexes don't know
    /// keyframes and return `n` itself — the demuxer seek lands on the real keyframe anyway.
    public func keyframe(atOrBefore n: Int) -> Int {
        guard isExact else { return clamp(n) }
        var lo = 0, hi = keyframeList.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if keyframeList[mid] <= n { lo = mid } else { hi = mid - 1 }
        }
        return keyframeList[lo]
    }

    /// Whether frame `n` is a keyframe. Approximate indexes know no keyframes.
    public func isKeyframe(_ n: Int) -> Bool {
        isExact && frameCount > 0 && keyframe(atOrBefore: n) == n
    }

    /// The first keyframe after frame `n` (exact indexes only).
    public func keyframe(after n: Int) -> Int? {
        guard isExact else { return nil }
        var lo = 0, hi = keyframeList.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if keyframeList[mid] <= n { lo = mid + 1 } else { hi = mid }
        }
        return lo < keyframeList.count ? keyframeList[lo] : nil
    }

    /// Where a keyframe seek from `current` toward `target` lands: the keyframe nearest to the
    /// target in time; if that lies against the seek direction, the nearest keyframe in the seek
    /// direction (or the last/first frame when there is none); never moves against `direction`. Nil for approximate indexes.
    public func keyframeSeekTarget(from current: Int, toward target: Int, direction: Int? = nil) -> Int? {
        guard isExact, frameCount > 0 else { return nil }
        let t = clamp(target)
        let before = keyframe(atOrBefore: t)
        var choice = before
        if let after = keyframe(after: t),
           seconds(forFrame: after) - seconds(forFrame: t) < seconds(forFrame: t) - seconds(forFrame: before) {
            choice = after
        }
        let dir = direction ?? (t < current ? -1 : t > current ? 1 : 0)   // explicit: a clamped target must not flip it
        if dir > 0 && choice <= current { return keyframe(after: current) ?? max(frameCount - 1, current) }
        if dir < 0 && choice >= current { return keyframe(atOrBefore: max(current - 1, 0)) }
        return choice
    }

    public func seconds(forFrame n: Int) -> Double {
        seconds(forPTS: pts(forFrame: n))
    }

    /// Seconds from the start of the video. For a decoded frame prefer its own pts: with an
    /// approximate index of a VFR file the frame number's time is only an estimate.
    public func seconds(forPTS pts: Int64) -> Double {
        Double(pts - zeroPTS) * timeBase
    }

    public func frameNumber(forSeconds seconds: Double) -> Int {
        frameNumber(forPTS: zeroPTS + Int64((seconds / timeBase).rounded()))
    }

    /// True when both indexes assign the same numbers to `other`'s frames (e.g. CFR video).
    public func agrees(with other: FrameIndex) -> Bool {
        frameCount == other.frameCount
            && (0..<other.frameCount).allSatisfy { frameNumber(forPTS: other.pts(forFrame: $0)) == $0 }
    }

    private func clamp(_ n: Int) -> Int { min(max(n, 0), max(frameCount - 1, 0)) }
}
