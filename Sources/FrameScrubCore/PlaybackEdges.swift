/// What playback does when the clock reaches an edge: the end of a mark (play-marks-only), A or B of the loop, or the
/// file's start or end. One place for both directions (reverse playback spec §3): going backward mirrors going forward.
public enum EdgeAction: Equatable, Sendable {
    case none
    case jump(Int)
    case pause(at: Int)
    /// Ping-pong: go on from this frame the other way.
    case turn(at: Int)
    case startOfFile, endOfFile
}

public enum PlaybackEdges {
    /// `n` is the frame the clock is at, `position` the one on screen; `pastStart` / `pastEnd`: the clock went beyond
    /// the first / last frame. `marks` only while play-marks-only is on (the loop is ignored then).
    public static func decide(target n: Int, pastStart: Bool, pastEnd: Bool, position: Int, direction: Int,
                              loop: ClosedRange<Int>?, mode: ABLoopMode, marks: [CutSegment]?, frameCount: Int) -> EdgeAction {
        let forward = direction > 0
        if let marks {
            if let i = marks.firstIndex(where: { $0.start <= position && position <= $0.end }) {
                let segment = marks[i]
                if forward, n > segment.end || pastEnd {
                    return i + 1 < marks.count ? .jump(marks[i + 1].start) : .pause(at: segment.end)
                }
                if !forward, n < segment.start || pastStart {
                    return i > 0 ? .jump(marks[i - 1].end) : .pause(at: segment.start)
                }
                return .none
            }
            if let start = markStart(position: position, direction: direction, marks: marks) { return .jump(start) }
        } else if let loop {
            let (a, b) = (loop.lowerBound, loop.upperBound)
            if forward, n > b || pastEnd {
                switch mode {
                case .loop: return .jump(a)
                case .once where position <= b: return .pause(at: b)
                case .pingPong where position <= b: return .turn(at: b)
                default: break   // started past B: plays on
                }
            }
            if !forward, n < a || pastStart {
                switch mode {
                case .loop: return .jump(b)
                case .once where position >= a: return .pause(at: a)
                case .pingPong where position >= a: return .turn(at: a)
                default: break   // started below A: plays on
                }
            }
        }
        if forward && pastEnd { return .endOfFile }
        if !forward && pastStart { return .startOfFile }
        return .none
    }

    /// Where playing the marks starts from outside them, going `direction`: forward the next mark's start (the first
    /// after the last, also from the end of the last); backward the end of the nearest mark below (the last one from
    /// below the first, also from the start of the first). Nil inside a mark.
    public static func markStart(position: Int, direction: Int, marks: [CutSegment]) -> Int? {
        guard let first = marks.first, let last = marks.last else { return nil }
        if direction > 0 {
            if position >= last.end { return first.start }
            guard !marks.contains(where: { $0.start <= position && position <= $0.end }) else { return nil }
            return marks.first { $0.start > position }?.start ?? first.start
        }
        if position <= first.start { return last.end }
        guard !marks.contains(where: { $0.start <= position && position <= $0.end }) else { return nil }
        return marks.last { $0.end < position }?.end ?? last.end
    }
}
