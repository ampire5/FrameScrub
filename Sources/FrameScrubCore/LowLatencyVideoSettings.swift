import Foundation

public enum LLScaleChoice: String, CaseIterable, Sendable {
    case off, auto, x1_5 = "1.5", x2 = "2", x4 = "4"

    public func factor(supported: [Float], ratio: Double) -> Float? {
        let factors = supported.filter { $0.isFinite && $0 > 1 }.sorted()
        switch self {
        case .off: return nil
        case .auto:
            guard ratio.isFinite, ratio > 1.05 else { return nil }
            return factors.first { Double($0) >= ratio } ?? factors.last
        default:
            let wanted = Float(rawValue)!
            return factors.first { abs($0 - wanted) < 0.001 }
        }
    }
}

public enum TemporalNoiseMode: String, Sendable { case paused, always }

public struct LowLatencyVideoSettings: Equatable, Sendable {
    public var scale = LLScaleChoice.off
    /// 0, 1 or 3 intermediate frames: original, double or quadruple frame rate.
    public var intermediateFrames = 0
    public var noiseEnabled = false
    public var noiseMode = TemporalNoiseMode.paused
    public var noiseStrength = 0.5
    public var noiseActive: Bool { noiseEnabled && noiseStrength.isFinite && noiseStrength > 0 }
    public init() {}
    public func forPlayback(playing: Bool) -> Self {
        var result = self
        if playing && noiseMode == .paused { result.noiseEnabled = false }
        return result
    }
    public var enabled: Bool { scale != .off || intermediateFrames > 0 || noiseActive }
}

public enum LLPresentation {
    public static func phaseIndex(at time: Double, start: Double, end: Double, count: Int) -> Int? {
        guard count > 0, time.isFinite, start.isFinite, end.isFinite, end > start, time >= start, time < end else { return nil }
        let index = Int(((time - start) / (end - start) * Double(count + 1)).rounded(.down)) - 1
        return index >= 0 ? min(index, count - 1) : nil
    }

    public static func canInterpolate(frame: Int, next: Int, start: Double, end: Double,
                                      playing: Bool, speed: Double, direction: Int) -> Bool {
        playing && speed == 1 && direction == 1 && next == frame + 1
            && start.isFinite && end.isFinite && end > start && end - start < 1
    }
}
