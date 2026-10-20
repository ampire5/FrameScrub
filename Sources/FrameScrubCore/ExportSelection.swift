import Foundation

/// Which frames of an A–B range an export saves.
public enum ExportSelection: Equatable, Sendable {
    case all
    case every(Int)
    case perSecond(Double)

    public init(config: Config) {
        switch config.exportMode {
        case .all: self = .all
        case .every: self = .every(config.exportEvery)
        case .fps: self = .perSecond(config.exportFPS)
        }
    }

    /// Frame numbers to save, ascending. `perSecond(F)` takes, for each instant t(A) + k/F up to t(B),
    /// the first frame that starts at or after it, which stays correct for variable frame rate.
    public func frames(in range: ClosedRange<Int>, index: FrameIndex) -> [Int] {
        switch self {
        case .all:
            return Array(range)
        case let .every(step):
            return Array(stride(from: range.lowerBound, through: range.upperBound, by: max(1, step)))
        case let .perSecond(fps):
            guard fps > 0, fps.isFinite else { return [] }
            let start = index.seconds(forFrame: range.lowerBound)
            let end = index.seconds(forFrame: range.upperBound)
            let epsilon = 1e-9
            var result: [Int] = []
            var k = 0
            while true {
                let t = start + Double(k) / fps
                if t > end + epsilon { break }
                var n = max(index.frameNumber(forSeconds: t), range.lowerBound)
                if index.seconds(forFrame: n) < t - epsilon { n += 1 }
                if n > range.upperBound { break }
                if result.last != n { result.append(n) }
                k += 1
            }
            return result
        }
    }

    /// The windows of a sharp-frames export (sharp export spec §3.1): one per selected frame, from it up to the
    /// frame before the next selected one; the last ends at the range's end. With `.all` each is a single frame.
    public func windows(in range: ClosedRange<Int>, index: FrameIndex) -> [ClosedRange<Int>] {
        let starts = frames(in: range, index: index)
        return starts.indices.map { i in starts[i]...(i + 1 < starts.count ? starts[i + 1] - 1 : range.upperBound) }
    }
}
