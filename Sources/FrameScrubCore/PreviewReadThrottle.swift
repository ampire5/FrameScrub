/// A cold hover read starts immediately. Subsequent reads are rate limited,
/// rather than postponed indefinitely while the pointer continues to move.
/// The preview worker owns this value; cached images bypass it.
public struct PreviewReadThrottle: Sendable {
    private let interval: Double
    private var lastStart: Double?
    public init(interval: Double) { self.interval = max(0, interval) }
    public func delay(at now: Double) -> Double {
        guard let lastStart else { return 0 }
        return max(0, interval - (now - lastStart))
    }
    public mutating func started(at now: Double) { lastStart = now }
}
