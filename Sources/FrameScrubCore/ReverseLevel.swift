/// How many of the frames reverse playback decodes (reverse playback spec §5): every frame, only the reference frames
/// (no frame refers to the others, so they need not be decoded), or only keyframes. Each is cheaper than the one before.
public enum ReverseLevel: Int, Comparable, CaseIterable, Sendable {
    case all, references, keyframes

    public static func < (a: ReverseLevel, b: ReverseLevel) -> Bool { a.rawValue < b.rawValue }

    private var cheaper: ReverseLevel? { ReverseLevel(rawValue: rawValue + 1) }
    private var costlier: ReverseLevel? { ReverseLevel(rawValue: rawValue - 1) }

    /// Without a measurement: every frame up to 2×, reference frames at 4×, keyframes beyond.
    public static func initial(speedMagnitude: Double) -> ReverseLevel {
        speedMagnitude <= 2 ? .all : speedMagnitude <= 4 ? .references : .keyframes
    }

    /// For a new speed: the costliest level whose own measurement keeps up with a 10 % margin; a level not measured yet
    /// is tried; with no measurement at all, `initial`. `coverage`: frames of video a level got through per second of
    /// decoding (nil: not measured); `needed`: frames of video per second the speed asks for.
    public static func best(coverage: (ReverseLevel) -> Double?, needed: Double, speedMagnitude: Double) -> ReverseLevel {
        guard allCases.contains(where: { coverage($0) != nil }) else { return initial(speedMagnitude: speedMagnitude) }
        return allCases.first { coverage($0).map { $0 >= 1.1 * needed } ?? true } ?? .keyframes
    }

    /// After a chunk: one level cheaper when the current one falls behind (under 1.1 × needed); one costlier only when
    /// that level's own measurement keeps up with room to spare (1.5 × needed) — what a cheaper level gets through says
    /// nothing about a costlier one, so the level does not swing back and forth.
    public static func next(current: ReverseLevel, coverage: (ReverseLevel) -> Double?, needed: Double) -> ReverseLevel {
        if let c = coverage(current), c < 1.1 * needed, let cheaper = current.cheaper { return cheaper }
        if let costlier = current.costlier, let c = coverage(costlier), c >= 1.5 * needed { return costlier }
        return current
    }
}
