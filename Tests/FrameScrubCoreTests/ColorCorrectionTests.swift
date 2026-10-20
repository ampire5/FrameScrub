import CoreImage
import Foundation
import Testing
@testable import FrameScrubCore

/// 64×64: left half a dull red (low saturation), right half neutral grey.
private func dullImage() -> CIImage {
    let dull = CIImage(color: CIColor(red: 0.55, green: 0.42, blue: 0.40)).cropped(to: CGRect(x: 0, y: 0, width: 32, height: 64))
    let grey = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: CGRect(x: 32, y: 0, width: 32, height: 64))
    return grey.composited(over: dull)
}

private func spread(_ pixel: [UInt8]) -> Int { Int(pixel[0...2].max()!) - Int(pixel[0...2].min()!) }

@Suite struct ColorCorrectionTests {
    @Test func identityLeavesTheImageUntouched() {
        let image = dullImage()
        #expect(ColorCorrection.identity.isIdentity)
        #expect(ColorCorrection.identity.apply(to: image) === image)
        #expect(ColorCorrection(vibrance: 0).apply(to: image) === image)
    }

    @Test func vibranceSaturatesDullColoursAndKeepsGreyGrey() {
        let image = dullImage()
        let boosted = ColorCorrection(vibrance: 1).apply(to: image)
        #expect(boosted.extent == image.extent)
        #expect(spread(samplePixel(boosted, x: 8, y: 32)) > spread(samplePixel(image, x: 8, y: 32)))
        #expect(spread(samplePixel(boosted, x: 48, y: 32)) <= 1)
    }

    @Test func autoAdjustmentIsComputedFromAFrameAndAppliedLater() throws {
        // A flat, low-contrast picture: the auto filters must find something to change.
        let flat = CIImage(color: CIColor(red: 0.45, green: 0.40, blue: 0.38)).cropped(to: CGRect(x: 0, y: 0, width: 32, height: 64))
            .composited(over: CIImage(color: CIColor(red: 0.35, green: 0.38, blue: 0.42)).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64)))
        let auto = ColorCorrection.autoAdjustment(for: flat)
        #expect(!auto.isEmpty)
        let corrected = ColorCorrection(auto: auto).apply(to: flat)
        #expect(corrected.extent == flat.extent)
        #expect(samplePixel(corrected, x: 8, y: 32) != samplePixel(flat, x: 8, y: 32))
    }

    @Test func autoStepsAreIndependentOfTheAnalysedImage() {
        // The stored steps hold parameters, not filters bound to the analysed frame.
        let auto = ColorCorrection.autoAdjustment(for: dullImage())
        let other = CIImage(color: CIColor(red: 0.2, green: 0.6, blue: 0.3)).cropped(to: CGRect(x: 0, y: 0, width: 10, height: 10))
        #expect(ColorCorrection(auto: auto).apply(to: other).extent == other.extent)
    }

    /// A low-contrast frame whose analysis returns more than one step.
    private func hazyImage() -> CIImage {
        let left = CIImage(color: CIColor(red: 0.45, green: 0.40, blue: 0.38)).cropped(to: CGRect(x: 0, y: 0, width: 32, height: 64))
        let right = CIImage(color: CIColor(red: 0.35, green: 0.38, blue: 0.42)).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64))
        return left.composited(over: right)
    }

    @Test func autoStepsAreSortedIntoTheThreeKinds() {
        let auto = ColorCorrection.autoAdjustment(for: hazyImage())
        #expect(!auto.isEmpty)
        #expect(auto.allSatisfy { AutoColorFilter.allCases.contains($0.kind) })
    }

    @Test func autoStrengthBlendsBetweenTheOriginalAndTheFullCorrection() {
        let image = hazyImage()
        let auto = ColorCorrection.autoAdjustment(for: image)
        let none = ColorCorrection(auto: auto, autoStrength: 0)
        #expect(none.isIdentity)
        #expect(none.apply(to: image) === image)
        let original = Int(samplePixel(image, x: 8, y: 32)[0])
        let full = Int(samplePixel(ColorCorrection(auto: auto).apply(to: image), x: 8, y: 32)[0])
        let half = Int(samplePixel(ColorCorrection(auto: auto, autoStrength: 0.5).apply(to: image), x: 8, y: 32)[0])
        #expect(full != original)
        #expect(half > min(original, full) && half < max(original, full))   // mixed in linear light, so not the sRGB midpoint
    }

    @Test func onlyTheChosenAutoFiltersAreApplied() throws {
        let image = hazyImage()
        let auto = ColorCorrection.autoAdjustment(for: image)
        let nothing = ColorCorrection(auto: auto, autoFilters: [])
        #expect(nothing.isIdentity)
        #expect(nothing.apply(to: image) === image)
        let kinds = Set(auto.map(\.kind))
        let one = try #require(kinds.first)
        let only = ColorCorrection(auto: auto, autoFilters: [one])
        #expect(only.activeAuto.map(\.kind) == auto.filter { $0.kind == one }.map(\.kind))
    }

    @Test func statsLineSaysWhatIsApplied() {
        #expect(ColorCorrection.identity.statusText(autoFrame: nil, saved: true) == "Colour: off")
        #expect(ColorCorrection(vibrance: 0.5).statusText(autoFrame: nil, saved: false) == "Colour: vibrance 0.5, files without it")
        #expect(ColorCorrection(vibrance: 0.5).statusText(autoFrame: nil, saved: true) == "Colour: vibrance 0.5, files with it")
        let auto = [ColorCorrection.Step(name: "CIToneCurve", kind: .curve, parameters: [:]),
                    ColorCorrection.Step(name: "CIHighlightShadowAdjust", kind: .shadows, parameters: [:])]
        let line = ColorCorrection(auto: auto, autoStrength: 0.8, autoFilters: [.shadows]).statusText(autoFrame: 42, saved: false)
        #expect(line == "Colour: auto 0.8 from frame 42 (shadows), files without it")
        #expect(ColorCorrection(auto: auto, autoFilters: []).statusText(autoFrame: 42, saved: false)
            == "Colour: auto 1 from frame 42 (nothing chosen), files without it")
    }

    @Test func statsLineMarksAFileOrFolderColour() {
        #expect(ColorCorrection(vibrance: 0.5).statusText(autoFrame: nil, saved: true, origin: .default)
            == "Colour: vibrance 0.5, files with it")
        #expect(ColorCorrection(vibrance: 0.5).statusText(autoFrame: nil, saved: true, origin: .folder)
            == "Colour: vibrance 0.5, files with it · folder")
        #expect(ColorCorrection.identity.statusText(autoFrame: nil, saved: true, origin: .file) == "Colour: off · file")
    }

    @Test func recomputeIsDueOnceTheFrameIsIntervalAwayFromTheAnalysedOne() {
        #expect(!AutoColorSchedule.isDue(interval: 0, analysedAt: 10, seconds: 100))       // off: only c
        #expect(!AutoColorSchedule.isDue(interval: 5, analysedAt: nil, seconds: 100))      // auto not on
        #expect(!AutoColorSchedule.isDue(interval: 5, analysedAt: 10, seconds: 10))        // paused on that frame
        #expect(!AutoColorSchedule.isDue(interval: 5, analysedAt: 10, seconds: 14.9))
        #expect(AutoColorSchedule.isDue(interval: 5, analysedAt: 10, seconds: 15))          // playing on
        #expect(AutoColorSchedule.isDue(interval: 5, analysedAt: 10, seconds: 2))           // jumped back
    }

    @Test func transitionGoesFromTheOldCorrectionToTheNewOne() {
        let image = dullImage()
        let old = ColorCorrection.identity
        let new = ColorCorrection(vibrance: 1)
        func red(_ progress: Double) -> UInt8 {
            samplePixel(ColorCorrection.transition(from: old, to: new, progress: progress, image: image), x: 8, y: 32)[0]
        }
        #expect(ColorCorrection.transition(from: old, to: new, progress: 0, image: image) === image)
        #expect(red(1) == samplePixel(new.apply(to: image), x: 8, y: 32)[0])
        #expect(red(0.5) > red(0) && red(0.5) < red(1))
        #expect(ColorCorrection.transition(from: old, to: new, progress: 0.5, image: image).extent == image.extent)
    }

    @Test func statsLineMentionsTheRecomputeInterval() {
        let auto = ColorCorrection.autoAdjustment(for: hazyImage())
        let line = ColorCorrection(auto: auto).statusText(autoFrame: 7, interval: 5, saved: false)
        #expect(line.hasPrefix("Colour: auto 1 from frame 7 every 5 s ("))
    }

    @Test func vibranceGainScalesTheAutoVibranceUpToOne() {
        let auto = [ColorCorrection.Step(name: "CIVibrance", kind: .vibrance, parameters: ["inputAmount": 0.12])]
        #expect(ColorCorrection(auto: auto).autoVibrance == 0.12)
        #expect(abs(ColorCorrection(auto: auto, autoVibranceGain: 4).autoVibrance! - 0.48) < 1e-9)
        #expect(ColorCorrection(auto: auto, autoVibranceGain: 10).autoVibrance == 1)
        #expect(ColorCorrection(auto: auto, autoFilters: [.curve]).autoVibrance == nil)
        let image = dullImage()
        let weak = spread(samplePixel(ColorCorrection(auto: auto).apply(to: image), x: 8, y: 32))
        let strong = spread(samplePixel(ColorCorrection(auto: auto, autoVibranceGain: 4).apply(to: image), x: 8, y: 32))
        #expect(strong > weak)
        #expect(ColorCorrection(auto: auto, autoVibranceGain: 4).statusText(autoFrame: 3, saved: false)
            == "Colour: auto 1 from frame 3 (vibrance 0.48), files without it")
    }

    @Test func statsLineSaysAutoColourIsWaitingForAPicture() {
        #expect(ColorCorrection.identity.statusText(autoFrame: nil, autoPending: true, saved: false)
            == "Colour: auto waiting for a picture, files without it")
    }

    @Test func nearlyBlackFramesAreTooDarkToAnalyse() {
        // Apple's analysis of a fade-in frame stretches the tones wildly; such frames are skipped when auto colour starts.
        let rect = CGRect(x: 0, y: 0, width: 64, height: 64)
        #expect(ColorCorrection.isTooDarkToAnalyse(CIImage(color: .black).cropped(to: rect)))
        #expect(ColorCorrection.isTooDarkToAnalyse(CIImage(color: CIColor(red: 0.03, green: 0.03, blue: 0.03)).cropped(to: rect)))
        #expect(!ColorCorrection.isTooDarkToAnalyse(hazyImage()))
        #expect(!ColorCorrection.isTooDarkToAnalyse(CIImage(color: CIColor(red: 0.2, green: 0.2, blue: 0.2)).cropped(to: rect)))
    }

    /// 640×360 with the whole range: black, white and saturated red, green and blue patches on mid grey.
    private func fullRangeImage() -> CIImage {
        var image = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: CGRect(x: 0, y: 0, width: 640, height: 360))
        let patches: [CIColor] = [.black, .white, CIColor(red: 1, green: 0, blue: 0), CIColor(red: 0, green: 1, blue: 0), CIColor(red: 0, green: 0, blue: 1)]
        for (i, colour) in patches.enumerated() {
            image = CIImage(color: colour).cropped(to: CGRect(x: i * 128, y: 0, width: 128, height: 180)).composited(over: image)
        }
        return image
    }

    @Test func analysisMeasuresHowMuchTheCorrectionChangesThePicture() {
        let hazy = ColorCorrection.analyse(hazyImage())
        #expect(hazy.delta > 6)
        #expect(ColorCorrection.analyse(fullRangeImage()).delta < hazy.delta)
        #expect(hazy.steps.map(\.name) == ColorCorrection.autoAdjustment(for: hazyImage()).map(\.name))
    }

    @Test func strengthRampsFromTheThresholdToFull() {
        func ramp(_ delta: Double, _ threshold: Double = 6, _ full: Double = 12) -> Double {
            AutoColorSchedule.rampStrength(delta: delta, threshold: threshold, full: full)
        }
        #expect(ramp(5) == 0)                       // below the threshold: left alone
        #expect(ramp(6) == 0)
        #expect(abs(ramp(9) - 0.5) < 1e-9)
        #expect(ramp(12) == 1)
        #expect(ramp(15) == 1)
        #expect(ramp(7, 6, 0) == 1)                 // full 0: whole strength from the threshold, as before
        #expect(ramp(7, 6, 5) == 1)                 // full at or below the threshold: the same
        #expect(abs(ramp(3, 0, 12) - 0.25) < 1e-9)  // threshold 0: every scene, in proportion
        #expect(ramp(0, 0, 0) == 1)
    }

    @Test func thresholdZeroAlwaysCorrects() {
        #expect(AutoColorSchedule.isNeeded(delta: 0, threshold: 0))
        #expect(AutoColorSchedule.isNeeded(delta: 6, threshold: 6))
        #expect(!AutoColorSchedule.isNeeded(delta: 5.99, threshold: 6))
    }

    @Test func statsLineShowsDeltaAndWhetherTheSceneNeedsIt() {
        let auto = [ColorCorrection.Step(name: "CIToneCurve", kind: .curve, parameters: [:]),
                    ColorCorrection.Step(name: "CIHighlightShadowAdjust", kind: .shadows, parameters: [:])]
        #expect(ColorCorrection(auto: auto).statusText(autoFrame: 1234, autoDelta: 9.4, saved: false)
            == "Colour: auto 1 from frame 1234, Δ 9.4 (curve, shadows), files without it")
        #expect(ColorCorrection().statusText(autoFrame: 1234, autoDelta: 3.1, saved: false)
            == "Colour: auto from frame 1234: Δ 3.1, needs none, files without it")
        #expect(ColorCorrection(auto: auto).statusText(autoFrame: 1234, interval: 5, autoDelta: 9.4, saved: false)
            == "Colour: auto 1 from frame 1234 every 5 s, Δ 9.4 (curve, shadows), files without it")
        #expect(ColorCorrection().statusText(autoFrame: 1234, interval: 5, autoDelta: 3.1, saved: false)
            == "Colour: auto from frame 1234 every 5 s: Δ 3.1, needs none, files without it")
        #expect(ColorCorrection(vibrance: 0.5).statusText(autoFrame: 1234, autoDelta: 3.1, saved: true)
            == "Colour: vibrance 0.5, auto from frame 1234: Δ 3.1, needs none, files with it")
    }
}
