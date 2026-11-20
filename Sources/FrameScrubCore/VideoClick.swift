/// AppKit counts consecutive mouse presses before it knows whether they will become force clicks.
public struct VideoClick {
    private var count: Int?
    private var previousWasPlain = false
    private var forceDelivered = false

    public init() {}

    public mutating func begin(count: Int) {
        self.count = forceDelivered ? nil : count
    }

    public mutating func drag() {
        count = nil
        previousWasPlain = false
    }

    /// Pressure can fall back to stage 1 and rise again during the same press.
    public mutating func pressure(stage: Int) -> Bool {
        if stage == 0 { forceDelivered = false }
        guard stage >= 2, !forceDelivered else { return false }
        forceDelivered = true
        count = nil
        previousWasPlain = false
        return true
    }

    /// A double click requires two completed plain presses.
    public mutating func end() -> Int? {
        let plainClick = count == 1 || (count == 2 && previousWasPlain) ? count : nil
        previousWasPlain = count != nil
        count = nil
        return plainClick
    }
}
