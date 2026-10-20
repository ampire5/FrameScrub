/// Time from a seek command to its target frame on screen (spec §5). A series of seeks is measured
/// from its last command.
public struct SeekTimer {
    private var started: Double?
    public private(set) var recent: [Double] = []

    public init() {}

    public var isRunning: Bool { started != nil }

    public mutating func start(at time: Double) { started = time }

    public mutating func finish(at time: Double) {
        guard let started else { return }
        self.started = nil
        recent.append(time - started)
        if recent.count > 10 { recent.removeFirst(recent.count - 10) }
    }

    public var text: String? {
        guard let last = recent.last else { return nil }
        let median = recent.sorted()[recent.count / 2]
        return "Seek: \(Int((last * 1000).rounded())) ms (median of last \(recent.count): \(Int((median * 1000).rounded())) ms)"
    }
}
