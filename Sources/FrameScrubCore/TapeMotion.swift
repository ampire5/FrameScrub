import Foundation

/// What the tape follows (scrub audio spec §6а): the frame on screen, when it was shown and how fast frames move.
public struct TapeControl: Equatable, Sendable {
    /// Media seconds of the frame on screen.
    public var target: Double
    /// Host seconds when it was shown.
    public var shownAt: Double
    /// Smoothed media seconds per host second.
    public var frameVelocity: Double
    /// False: fade out now (playback started, scrub audio off).
    public var running: Bool
    /// Read straight at the position (`tape`) or through `GrainStretcher` (`natural`, spec §6б).
    public var pitch: ScrubPitch

    public init(target: Double, shownAt: Double, frameVelocity: Double, running: Bool, pitch: ScrubPitch = .tape) {
        self.target = target
        self.shownAt = shownAt
        self.frameVelocity = frameVelocity
        self.running = running
        self.pitch = pitch
    }
}

/// How fast the frames on screen move: the distance over the last 0.3 s of frames, so a mouse wheel's staircase
/// (several frames per notch) and a decoder's bursts (frames milliseconds apart) read as their average speed. Capped
/// at the tape's ±4×; 0 after a pause longer than the hold or after a jump; a turn of direction starts it afresh.
public struct FrameVelocity {
    private static let window = 0.3
    private static let minimumSpan = 0.03
    private var history: [(target: Double, host: Double)] = []
    private var velocity = 0.0

    public init() {}

    public mutating func shown(_ target: Double, at host: Double) -> Double {
        if let last = history.last, host < last.host || host - last.host > TapeMotion.activeFor
            || abs(target - last.target) > TapeMotion.jumpDistance {
            history.removeAll()
            velocity = 0
        }
        // A turn of direction starts the average again, so the tape turns with the picture, not 0.3 s later.
        if history.count >= 2, let last = history.last {
            let before = last.target - history[history.count - 2].target, now = target - last.target
            if before * now < 0 { history.removeFirst(history.count - 1) }
        }
        history.append((target, host))
        while history.count > 2 && host - history[1].host >= Self.window { history.removeFirst() }
        guard let first = history.first, host - first.host >= Self.minimumSpan else { return velocity }
        velocity = max(-TapeMotion.maxSpeed, min(TapeMotion.maxSpeed, (target - first.target) / (host - first.host)))
        return velocity
    }
}

/// The tape's position, speed and loudness, advanced one output sample at a time (spec §6а). Speed follows the
/// frames' average speed plus a gentle correction that closes the gap to the frame in ~0.3 s, capped at ±4×, so the
/// pitch stays steady under a wheel's staircase. It starts at the frames' speed (no glide up from 0); a gap over
/// 0.5 s is a jump (fade out, move, fade in at the same speed); with no new frame for 0.3 s it fades out at the
/// speed it had — no pitch glides at either end.
public struct TapeMotion {
    static let activeFor = 0.3
    static let jumpDistance = 0.5
    static let maxSpeed = 4.0
    private static let catchUp = 0.3
    private static let slew = 0.05
    private static let fadeIn = 0.02
    private static let fadeOut = 0.05
    private static let jumpFade = 0.01
    private static let stopFade = 0.005

    public private(set) var position = 0.0
    public private(set) var velocity = 0.0
    public private(set) var gain: Float = 0
    private var jumping = false

    public init() {}

    private static func capped(_ v: Double) -> Double { max(-maxSpeed, min(maxSpeed, v)) }

    /// Advances by one output sample of `dt` seconds at host time `now`; returns the media position to read.
    public mutating func step(dt: Double, now: Double, control: TapeControl) -> Double {
        let since = now - control.shownAt
        let active = control.running && since >= 0 && since <= Self.activeFor
        let expected = control.target + control.frameVelocity * max(0, since)
        if gain == 0 && !jumping {
            guard active && control.frameVelocity != 0 else {
                velocity = 0
                return position
            }
            position = expected   // silent: start right at the frame, at the frames' speed
            velocity = Self.capped(control.frameVelocity)
        }
        var targetVelocity = velocity   // held while fading out or jumping
        if active && !jumping {
            let error = expected - position
            if abs(error) > Self.jumpDistance {
                jumping = true
            } else {
                targetVelocity = Self.capped(control.frameVelocity + error / Self.catchUp)
            }
        }
        let targetGain: Float = active && !jumping ? 1 : 0
        let fade = jumping ? Self.jumpFade : !control.running ? Self.stopFade : active ? Self.fadeIn : Self.fadeOut
        let ramp = Float(dt / fade)
        gain = targetGain > gain ? min(targetGain, gain + ramp) : max(targetGain, gain - ramp)
        if gain == 0 && targetGain == 0 {
            if jumping {
                jumping = false
                position = expected
                velocity = active ? Self.capped(control.frameVelocity) : 0
            } else {
                velocity = 0
            }
            return position
        }
        velocity += (targetVelocity - velocity) * min(1, dt / Self.slew)
        position += velocity * dt
        return position
    }
}
