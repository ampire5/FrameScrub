import CoreGraphics

/// Recognizes two brief three-finger contacts from snapshots of the active indirect touches.
public struct ThreeFingerDoubleTap<ID: Hashable> {
    // Match Loupe's three-finger tap tolerances, in seconds and normalized trackpad coordinates.
    private let maxDuration = 0.3
    private let maxDrift = 0.02
    private var start: Double?
    private var origins: [ID: CGPoint] = [:]
    private var reachedThree = false
    private var rejected = false
    private var lastTap: Double?

    public init() {}

    /// Clears a pending pair and rejects the current contact until the fingers lift.
    public mutating func cancel() {
        lastTap = nil
        rejected = start != nil
    }

    public mutating func update(_ touches: [ID: CGPoint], at time: Double, interval: Double) -> Bool {
        if touches.isEmpty {
            guard let start else { return false }
            let isTap = reachedThree && !rejected && time - start <= maxDuration
            let isPair = isTap && lastTap.map { time - $0 <= interval } == true
            self = Self()
            if isTap && !isPair { lastTap = time }
            return isPair
        }

        if start == nil { start = time }
        guard !rejected else { return false }
        guard touches.count <= 3 else { cancel(); return false }
        for (id, position) in touches {
            let origin = origins[id, default: position]
            if hypot(position.x - origin.x, position.y - origin.y) > maxDrift {
                cancel()
                return false
            }
            origins[id] = origin
        }
        if origins.count > 3 { cancel() }
        reachedThree = reachedThree || touches.count == 3
        return false
    }
}
