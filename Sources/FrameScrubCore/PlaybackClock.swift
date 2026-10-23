import QuartzCore

/// Media time on the video timeline. While running it follows the audio output when audio is
/// audible, otherwise the host clock scaled by `rate`. While the sound is still starting (`audioStarting`) the clock
/// holds where it started, for at most `audioStartLimit` seconds, so picture and sound begin together: running on the
/// host clock meanwhile would put the picture ahead and then jump it back to the sound.
public final class PlaybackClock {
    public var audioSeconds: (() -> Double?)?
    /// True from asking the sound to play until it is heard (or has given up).
    public var audioStarting: (() -> Bool)?
    /// The longest the clock holds for a starting sound; then it runs on the host clock from where it held.
    public let audioStartLimit = 1.0
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
    /// Host time until which a starting sound holds the clock (`start`).
    private var holdUntil = -Double.infinity

    public init(now: @escaping () -> Double = CACurrentMediaTime) {
        self.now = now
    }

    public var seconds: Double {
        guard isRunning else { return baseSeconds }
        if followsAudio {
            if let audio = audioSeconds?() { return audio }
            let t = now()
            if t < holdUntil, audioStarting?() == true {
                baseTime = t   // held: the host time runs on from here once the hold ends
                return baseSeconds
            }
        }
        return baseSeconds + (now() - baseTime) * rate
    }

    public func start(at seconds: Double) {
        baseSeconds = seconds
        baseTime = now()
        holdUntil = baseTime + audioStartLimit
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
