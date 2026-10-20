public enum ToneMapPlan: Equatable, Sendable {
    case none
    case toSDR
    case toHeadroom(Double)

    /// At or below this EDR headroom a screen is treated as SDR.
    public static let sdrHeadroomLimit = 1.05

    public static func resolve(range: DynamicRange, displayHeadroom: Double) -> ToneMapPlan {
        guard range != .sdr else { return .none }
        return displayHeadroom <= sdrHeadroomLimit ? .toSDR : .toHeadroom(displayHeadroom)
    }
}
