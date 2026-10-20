/// How the picture gets from source pixels to on-screen pixels.
public enum ScalerChoice: Equatable, Sendable {
    case none, metalFX, lanczos, bilinear

    /// Ratios inside this band count as "not scaled".
    public static let neutralBand = 0.95...1.05

    /// `ratio` = on-screen pixels / source pixels along the fitted axis.
    public static func choose(mode: ScaleMode, ratio: Double, metalFXAvailable: Bool) -> ScalerChoice {
        guard ratio.isFinite, ratio > 0 else { return .none }
        let upscaling = ratio > neutralBand.upperBound
        let downscaling = ratio < neutralBand.lowerBound
        switch mode {
        case .bilinear:
            return .bilinear
        case .lanczos:
            return upscaling || downscaling ? .lanczos : .none
        case .auto, .metalfx:
            if upscaling { return metalFXAvailable ? .metalFX : .lanczos }
            return downscaling ? .lanczos : .none
        }
    }
}
