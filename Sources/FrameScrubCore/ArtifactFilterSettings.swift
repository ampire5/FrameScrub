/// Display-only experimental spatial filters. Defaults leave the picture untouched.
public struct ArtifactFilterSettings: Equatable, Sendable {
    public enum Antiring: String, CaseIterable, Sendable { case off, luma, edge, directional }
    public enum Deband: String, CaseIterable, Sendable { case off, single, double, adaptive, reference, window }
    public enum Chroma: String, CaseIterable, Sendable { case off, bilateral, wide, median }
    public enum Comparison: String, CaseIterable, Sendable { case processed, bypass, split, changes }
    public enum Grain: String, CaseIterable, Sendable {
        case off, white, fine, soft, av1, particles
        var templateIndex: Int {
            switch self {
            case .off, .white: 0
            case .fine: 1
            case .soft: 2
            case .av1: 3
            case .particles: 4
            }
        }
    }
    public var grain = Grain.off
    /// Approximate RGB8-code RMS before the mask/luminance response.
    public var grainAmount = 0.65
    public var grainSize = 1.0
    public var grainBase = 0.25
    public var grainAdaptation = 1.0
    public var enabled = true
    public var antiring = Antiring.off
    public var deband = Deband.off
    public var chroma = Chroma.off
    public var comparison = Comparison.processed
    public var strength = 1.0
    public var antiringStrength = 1.0
    public var debandStrength = 0.5
    public var debandThreshold = 9.0
    public var debandRadius = 24.0
    public var debandIterations = 1
    public var textureProtection = 1.0
    public var chromaStrength = 0.5
    public var dither = 0.0
    public init() {}
    /// Only cleanup controls: perceptual grain and output dither are kept as selected.
    public static let cleanupKeys = ["artifact-enabled", "artifact-strength", "artifact-compare", "artifact-deband", "artifact-deband-strength", "artifact-deband-threshold", "artifact-deband-radius", "artifact-deband-iterations", "artifact-texture-protection", "artifact-chroma", "artifact-chroma-strength", "artifact-antiring", "artifact-antiring-strength"]
    public mutating func applyCleanup(strong: Bool) {
        enabled = true; strength = 1; comparison = .processed
        deband = .window; debandStrength = strong ? 0.95 : 0.5
        debandThreshold = strong ? 12 : 9; debandRadius = strong ? 32 : 24
        debandIterations = 1; textureProtection = 1
        chroma = .off
        antiring = .off; antiringStrength = 1
    }
    /// Experimental working preset; global defaults remain unchanged.
    public static func texturedCleanup(grain: Grain) -> Self {
        var s=Self()
        s.deband = .window; s.debandStrength=0.8; s.debandThreshold=12; s.debandRadius=32
        s.grain=grain; s.grainAmount=6; s.grainSize=2; s.grainBase=0.8
        return s
    }
    /// libplacebo sampling defaults (threshold 3/1000, radius 16, one iteration),
    /// without its optional grain. Lab thresholds are expressed in RGB8 code units.
    public static var referencePreset: Self {
        var s=Self();s.deband = .reference;s.debandThreshold=0.765;s.debandRadius=16;s.debandStrength=1
        return s
    }
    public var active: Bool { enabled && strength > 0 && ((antiring != .off && antiringStrength > 0) || (deband != .off && debandStrength > 0) || (chroma != .off && chromaStrength > 0) || dither > 0 || (grain != .off && grainAmount > 0)) }
    public func applies(hdr: Bool) -> Bool { active && !hdr && comparison != .bypass }
    public var summary: String {
        guard enabled else { return "Filters: bypass" }
        guard active else { return "Filters: off" }
        if comparison == .bypass { return "Filters: A/B bypass" }
        let modes = [antiring == .off ? nil : "AR \(antiring.rawValue)", deband == .off ? nil : "deband \(deband.rawValue)", chroma == .off ? nil : "chroma \(chroma.rawValue)", dither > 0 ? "dither" : nil, grain != .off && grainAmount > 0 ? "grain \(grain.rawValue)" : nil].compactMap { $0 }
        return "Filters: " + modes.joined(separator: ", ") + (comparison == .split ? " (split)" : comparison == .changes ? " (changes)" : "")
    }
}
