import QuartzCore

/// Media time on the video timeline. While running it follows the audio output when audio is
/// audible, otherwise the host clock scaled by `rate`.
public final class PlaybackClock {
    public var audioSeconds: (() -> Double?)?
    /// Off while playing backward (reverse playback spec §3): the audio is paused, the host clock runs backward.
    public var followsAudio = true {
        willSet { rebase() }
    }
    public private(set) var isRunning = false
    public var rate = 1.0 {
        willSet { rebase() }
    }

    private let now: () -> Double
    private var baseSeconds = 0.0
    private var baseTime = 0.0

    public init(now: @escaping () -> Double = CACurrentMediaTime) {
        self.now = now
    }

    public var seconds: Double {
        guard isRunning else { return baseSeconds }
        if followsAudio, let audio = audioSeconds?() { return audio }
        return baseSeconds + (now() - baseTime) * rate
    }

    public func start(at seconds: Double) {
        baseSeconds = seconds
        baseTime = now()
        isRunning = true
    }

    public func stop() {
        baseSeconds = seconds
        isRunning = false
    }

    private func rebase() {
        baseSeconds = seconds
        baseTime = now()
    }
}
