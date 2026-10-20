/// Picks the sharpest frame of each export window and keeps it only when it is sharp enough next to its
/// neighbours (sharp export spec §3.2). Pure logic: the exporter feeds decoded frames, tests feed numbers.
public struct SharpPicker<Payload> {
    public struct Decision {
        public let window: Int
        public let payload: Payload
        public let write: Bool
    }

    private struct Candidate {
        let window: Int
        let score: Double?
        let payload: Payload
    }

    /// 0…1: share of the neighbours' median a window's best score needs.
    public let threshold: Double
    /// Windows w − reach … w + reach form the median of window w.
    private let reach: Int
    private var current: Candidate?
    /// Complete windows waiting for later neighbours, ascending.
    private var pending: [Candidate] = []
    /// Best score of every complete window that has one.
    private var scores: [Int: Double] = [:]
    private var lastComplete: Int?

    public init(threshold: Double, neighbours: Int) {
        self.threshold = threshold
        reach = max(0, neighbours / 2)
    }

    /// Offers a frame of `window` (windows ascending, the frames of a window together). Returns the windows
    /// this decides, in order.
    public mutating func add(window: Int, score: Double?, payload: Payload) -> [Decision] {
        if let current, current.window == window {
            if (score ?? -.infinity) > (current.score ?? -.infinity) {
                self.current = Candidate(window: window, score: score, payload: payload)
            }
            return []
        }
        complete()
        current = Candidate(window: window, score: score, payload: payload)
        return decide(final: false)
    }

    /// The range has ended: decides every window still waiting.
    public mutating func finish() -> [Decision] {
        complete()
        return decide(final: true)
    }

    private mutating func complete() {
        guard let done = current else { return }
        current = nil
        pending.append(done)
        if let score = done.score { scores[done.window] = score }
        lastComplete = done.window
    }

    private mutating func decide(final: Bool) -> [Decision] {
        var decisions: [Decision] = []
        while let next = pending.first, final || (lastComplete ?? .min) >= next.window + reach {
            pending.removeFirst()
            decisions.append(Decision(window: next.window, payload: next.payload, write: isSharpEnough(next)))
        }
        return decisions
    }

    private func isSharpEnough(_ candidate: Candidate) -> Bool {
        guard let score = candidate.score else { return true }   // unmeasurable: rather an extra file than a lost one
        let around = (candidate.window - reach...candidate.window + reach).compactMap { scores[$0] }.sorted()
        let middle = around.count / 2
        let median = around.count % 2 == 1 ? around[middle] : (around[middle - 1] + around[middle]) / 2
        return score >= threshold * median
    }
}
