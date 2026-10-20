import Testing
@testable import FrameScrubCore

@Suite struct ScalerChoiceTests {
    @Test func autoUsesMetalFXToUpscaleAndLanczosToDownscale() {
        #expect(ScalerChoice.choose(mode: .auto, ratio: 3.2, metalFXAvailable: true) == .metalFX)
        #expect(ScalerChoice.choose(mode: .auto, ratio: 1.06, metalFXAvailable: true) == .metalFX)
        #expect(ScalerChoice.choose(mode: .auto, ratio: 0.5, metalFXAvailable: true) == .lanczos)
        #expect(ScalerChoice.choose(mode: .auto, ratio: 0.94, metalFXAvailable: true) == .lanczos)
    }

    @Test func autoDoesNotScaleNearOne() {
        for ratio in [0.95, 0.99, 1.0, 1.04, 1.05] {
            #expect(ScalerChoice.choose(mode: .auto, ratio: ratio, metalFXAvailable: true) == .none)
        }
    }

    @Test func missingMetalFXFallsBackToLanczos() {
        #expect(ScalerChoice.choose(mode: .auto, ratio: 2, metalFXAvailable: false) == .lanczos)
        #expect(ScalerChoice.choose(mode: .metalfx, ratio: 2, metalFXAvailable: false) == .lanczos)
    }

    @Test func explicitModes() {
        #expect(ScalerChoice.choose(mode: .metalfx, ratio: 2, metalFXAvailable: true) == .metalFX)
        #expect(ScalerChoice.choose(mode: .metalfx, ratio: 0.5, metalFXAvailable: true) == .lanczos)
        #expect(ScalerChoice.choose(mode: .lanczos, ratio: 2, metalFXAvailable: true) == .lanczos)
        #expect(ScalerChoice.choose(mode: .lanczos, ratio: 1, metalFXAvailable: true) == .none)
        #expect(ScalerChoice.choose(mode: .bilinear, ratio: 2, metalFXAvailable: true) == .bilinear)
        #expect(ScalerChoice.choose(mode: .bilinear, ratio: 0.5, metalFXAvailable: true) == .bilinear)
    }

    @Test func nonsenseRatioMeansNoScaling() {
        for ratio in [0.0, -1.0, Double.nan, Double.infinity] {
            #expect(ScalerChoice.choose(mode: .auto, ratio: ratio, metalFXAvailable: true) == .none)
        }
    }
}
