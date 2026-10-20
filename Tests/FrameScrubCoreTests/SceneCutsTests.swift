import CoreImage
import Foundation
import Testing
@testable import FrameScrubCore

private func solid(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, width: CGFloat = 640, height: CGFloat = 360) -> CIImage {
    CIImage(color: CIColor(red: red, green: green, blue: blue)).cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
}

private let darkBlue = solid(0.05, 0.1, 0.35)
private let brightOrange = solid(0.95, 0.6, 0.2)

@Suite struct SceneCutsTests {
    @Test func identicalFramesDoNotDiffer() {
        #expect(SceneSignature.of(darkBlue).difference(.of(darkBlue)) == 0)
    }

    @Test func aSmallChangeIsNotACut() {
        let patch = solid(0.1, 0.15, 0.4).cropped(to: CGRect(x: 300, y: 170, width: 20, height: 20))
        let difference = SceneSignature.of(darkBlue).difference(.of(patch.composited(over: darkBlue)))
        #expect(difference > 0)
        #expect(difference < SceneCutDetector.defaultThreshold)
    }

    @Test func aDifferentPictureIsACut() {
        #expect(SceneSignature.of(darkBlue).difference(.of(brightOrange)) >= SceneCutDetector.defaultThreshold)
    }

    @Test func theFirstFrameAndTheFirstAfterResetAreCuts() {
        var detector = SceneCutDetector()
        let blue = SceneSignature.of(darkBlue), orange = SceneSignature.of(brightOrange)
        let first = detector.isCut(blue), same = detector.isCut(blue), other = detector.isCut(orange)
        detector.reset()
        let afterReset = detector.isCut(orange)
        #expect(first && !same && other && afterReset)
    }

    @Test func anyAspectGivesTheSameSignatureSize() {
        let portrait = solid(0.3, 0.5, 0.2, width: 360, height: 640)
        let wide = solid(0.3, 0.5, 0.2, width: 1920, height: 1080)
        #expect(SceneSignature.of(portrait).difference(.of(wide)) == 0)   // edges included
    }

    @Test func changedShareCountsCellsAboveTheNoise() {
        let quarter = brightOrange.cropped(to: CGRect(x: 0, y: 0, width: 320, height: 180)).composited(over: darkBlue)
        let share = SceneSignature.of(darkBlue).changedShare(.of(quarter), noise: 16)
        #expect(abs(share - 0.25) < 0.03)   // Lanczos blurs one cell row and column at the patch's edge
        #expect(SceneSignature.of(darkBlue).changedShare(.of(darkBlue), noise: 0) == 0)
        let faint = solid(0.07, 0.12, 0.37).cropped(to: CGRect(x: 0, y: 0, width: 320, height: 180)).composited(over: darkBlue)
        #expect(SceneSignature.of(darkBlue).changedShare(.of(faint), noise: 16) == 0)   // 5 of 255: noise
    }

    @Test func aFrameInsideTheSlotWaitsForItsEnd() {
        var sampling = SceneSampling()
        #expect(sampling.decide(frame: 1, at: 0) == .now)
        guard case .later(let wait) = sampling.decide(frame: 2, at: 0.01) else { Issue.record("not delayed"); return }
        #expect(abs(wait - (1.0 / 30 - 0.01)) < 1e-9)
        #expect(sampling.decide(frame: 2, at: 1.0 / 30) == .now)   // caught up when the slot ends
    }

    @Test func aFrameIsComparedOnlyOnceUntilReset() {
        var sampling = SceneSampling()
        #expect(sampling.decide(frame: 7, at: 0) == .now)
        #expect(sampling.decide(frame: 7, at: 1) == .skip)   // paused: settings changed, or a catch-up for it
        sampling.reset()
        #expect(sampling.decide(frame: 7, at: 1) == .now)
    }

    @Test func sixtyFramesASecondGiveAtMostThirtySignatures() {
        // The player: a frame every 1/60 s; a delayed one schedules a catch-up of the frame then on screen.
        var sampling = SceneSampling()
        var sent = 0
        var catchUp: Double?
        for n in 0..<60 {
            let time = Double(n) / 60
            if let due = catchUp, due <= time {
                catchUp = nil
                if sampling.decide(frame: n - 1, at: due) == .now { sent += 1 }
            }
            switch sampling.decide(frame: n, at: time) {
            case .now: sent += 1
            case .later(let wait): if catchUp == nil { catchUp = time + wait }
            case .skip: break
            }
        }
        #expect(sent <= 31)
        #expect(sent >= 29)
    }
}
