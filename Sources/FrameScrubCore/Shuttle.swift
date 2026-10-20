/// Paused or playing, which way, how fast (`speed` is the magnitude; `direction` stays the last one while paused).
public struct PlayState: Equatable, Sendable {
    public var paused: Bool
    public var direction: Int
    public var speed: Double

    public init(paused: Bool, direction: Int, speed: Double) {
        self.paused = paused
        self.direction = direction
        self.speed = speed
    }
}

public enum ShuttleKey: Sendable { case back, stop, forward }

/// The J/K/L shuttle of editing apps (reverse playback spec §2): a direction key starts that way at 1× from a pause
/// or from the other direction, and steps up 1 → 2 → 4 → 8× while already going that way; stop pauses.
public enum Shuttle {
    public static let steps: [Double] = [1, 2, 4, 8]

    public static func press(_ key: ShuttleKey, in state: PlayState) -> PlayState {
        var next = state
        switch key {
        case .stop:
            next.paused = true
        case .back, .forward:
            let direction = key == .forward ? 1 : -1
            if state.paused || state.direction != direction {
                return PlayState(paused: false, direction: direction, speed: 1)
            }
            next.speed = steps.first { $0 > state.speed + 1e-9 } ?? steps.last!
        }
        return next
    }
}
