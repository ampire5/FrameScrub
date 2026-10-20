import Foundation

/// `wheel-precision-mode`: what sets the frames a notch of a high-resolution wheel moves a plain scrub.
public enum WheelPrecisionMode: String, Sendable {
    /// `wheel-precision-frames` frames, whatever the video.
    case frames
    /// `wheel-precision-time` of video, turned into frames by its frame rate.
    case fps
}

public struct ScrubSettings: Equatable, Sendable {
    public var pxPerFrame = 8.0
    /// `scrub-accel-from`: frames/s of the plain scrub above which acceleration starts.
    public var accelFrom = 20.0
    /// `scrub-accel-max`: frames/s acceleration takes the scrub to at most (a faster plain scrub stays as fast).
    public var accelMax = 240.0
    public var invert = false
    /// Step multiplier of the fast scrub action (`scrub fast`).
    public var fastMultiplier = 10.0
    /// `scrub-accel`: faster movement takes bigger steps; off, every frame is visited (one per notch / `pxPerFrame`).
    public var accelerate = true
    /// `wheel-precision-frames`: frames a notch of a high-resolution wheel moves a plain scrub (0.5…6; 6 = a frame
    /// per event of the ~6 a notch sends).
    public var precisionFramesPerNotch = 6.0
    public var precisionMode = WheelPrecisionMode.frames
    /// `wheel-precision-time`: milliseconds of video a notch covers in the `fps` mode (20…250).
    public var precisionMsPerNotch = 100.0

    public init(pxPerFrame: Double = 8, accelFrom: Double = 20, accelMax: Double = 240,
                invert: Bool = false, fastMultiplier: Double = 10) {
        self.pxPerFrame = pxPerFrame
        self.accelFrom = accelFrom
        self.accelMax = accelMax
        self.invert = invert
        self.fastMultiplier = fastMultiplier
    }
}

/// Turns horizontal scroll input into frame steps (positive = forward).
/// Slow movement steps exactly one frame per `pxPerFrame` points (a wheel: per notch); faster movement multiplies
/// the step (`multiplier(forFramesPerSecond:)`); trackpad momentum is ignored so scrubbing stops when the fingers lift.
public final class ScrubController {
    public var settings: ScrubSettings
    /// Frame rate of the open video, for `wheel-precision-mode=fps`.
    public var videoFPS = 30.0
    /// The acceleration (`multiplier(forFramesPerSecond:)`) the last `wheelTick` used, the fast scrub's boost not
    /// counted: 1 for a wheel turned slowly or with `scrub-accel=no`.
    public private(set) var lastMultiplier = 1.0
    private var samples: [(time: Double, distance: Double)] = []
    private var accumulator = 0.0
    private var lastSign = 0
    private var wheelTimes: [Double] = []
    /// Fraction of a frame carried between high-resolution wheel events (signed, in frames).
    private var wheelCarry = 0.0
    private var wheelSign = 0

    private static let velocityWindow = 0.08
    private static let wheelWindow = 0.3

    public init(settings: ScrubSettings = .init()) {
        self.settings = settings
    }

    public func reset() {
        samples.removeAll()
        accumulator = 0
        lastSign = 0
        wheelTimes.removeAll()
        wheelCarry = 0
        wheelSign = 0
    }

    /// Step multiplier for a plain scrub running at `speed` frames/s: from `accelFrom` the steps grow with the speed
    /// (twice as fast, twice the steps), up to `accelMax` frames/s; never below 1.
    public func multiplier(forFramesPerSecond speed: Double) -> Double {
        guard settings.accelerate, speed > settings.accelFrom else { return 1 }
        return max(1, min(speed / settings.accelFrom, settings.accelMax / speed))
    }

    /// Trackpad / Magic Mouse delta (points). `boost` multiplies the step (fast scrub);
    /// `invert` flips the direction on top of `settings.invert`.
    public func preciseDelta(_ deltaX: Double, at time: Double, isMomentum: Bool,
                             boost: Double = 1, invert: Bool = false) -> Int {
        guard !isMomentum, deltaX != 0 else { return 0 }
        let signed = settings.invert != invert ? deltaX : -deltaX
        let sign = signed > 0 ? 1 : -1
        if sign != lastSign {
            accumulator = 0
            samples.removeAll()
            lastSign = sign
        }
        samples.append((time, abs(deltaX)))
        samples.removeAll { $0.time <= time - Self.velocityWindow }
        let velocity = samples.reduce(0) { $0 + $1.distance } / Self.velocityWindow
        accumulator += signed * multiplier(forFramesPerSecond: velocity / settings.pxPerFrame) * boost
        let frames = Int(accumulator / settings.pxPerFrame)
        accumulator -= Double(frames) * settings.pxPerFrame
        return frames
    }

    /// One event of a mouse wheel; `deltaSign` is the sign of the scroll delta. A regular wheel sends one event a
    /// notch. A high-resolution one sends `eventsPerNotch`: a plain scrub then moves `precisionFrames` a notch
    /// (the fraction carried between events), a boosted (fast) one keeps its frames per notch (never fewer
    /// than plain). Acceleration goes by the frames/s of the plain scrub.
    public func wheelTick(deltaSign: Int, at time: Double, boost: Double = 1, invert: Bool = false,
                          eventsPerNotch: Int = 1) -> Int {
        guard deltaSign != 0 else { return 0 }
        let forward = settings.invert != invert ? deltaSign : -deltaSign
        let sign = forward > 0 ? 1 : -1
        let perNotch = Double(max(eventsPerNotch, 1))
        wheelTimes.append(time)
        wheelTimes.removeAll { $0 <= time - Self.wheelWindow }
        let notchesPerSecond = Double(wheelTimes.count) / Self.wheelWindow / perNotch
        guard eventsPerNotch > 1 else {
            let m = multiplier(forFramesPerSecond: notchesPerSecond)
            lastMultiplier = m
            return sign * Int((m * boost).rounded())
        }
        let framesPerNotch = precisionFrames(eventsPerNotch: perNotch)
        let m = multiplier(forFramesPerSecond: notchesPerSecond * framesPerNotch)
        lastMultiplier = m
        if sign != wheelSign {
            wheelCarry = 0
            wheelSign = sign
        }
        let plain = m * framesPerNotch / perNotch
        // A fast scrub is never slower than a plain one, whatever `scrub-fast-multiplier` is.
        wheelCarry += Double(sign) * (boost > 1 ? max(m * boost / perNotch, plain) : plain)
        // The nudge keeps sums like 6 × 1/6 from landing a hair short of a whole frame.
        let frames = Int(wheelCarry + Double(sign) * 1e-9)
        wheelCarry -= Double(frames)
        return frames
    }

    /// Frames a notch of a high-resolution wheel moves a plain scrub: at most a frame per event (a scrub visits every
    /// frame) and at least half a frame.
    private func precisionFrames(eventsPerNotch: Double) -> Double {
        let frames = switch settings.precisionMode {
        case .frames: settings.precisionFramesPerNotch
        case .fps: settings.precisionMsPerNotch / 1000 * videoFPS
        }
        return min(max(frames, 0.5), eventsPerNotch)
    }
}
