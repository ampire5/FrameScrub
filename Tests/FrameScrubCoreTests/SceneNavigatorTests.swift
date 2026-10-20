import Testing
@testable import FrameScrubCore

private func sig(_ v: UInt8) -> SceneSignature {
    SceneSignature(rgb: [UInt8](repeating: v, count: SceneSignature.width * SceneSignature.height * 3))
}
private func p(_ v: UInt8) -> KeyframeLook { .picture(sig(v)) }
private func chain(_ items: [(Int, KeyframeLook)]) -> [(frame: Int, look: KeyframeLook)] {
    items.map { (frame: $0.0, look: $0.1) }
}
private let seconds: (Int) -> Double = { Double($0) / 25 }

private func forward(_ position: Int, _ items: [(Int, KeyframeLook)], scenes: Int = 1, atEdge: Bool = false,
                     verified: [Int: [Int]] = [:], threshold: Double = 25, mayVerify: Bool = true) -> SceneNavigator.Step {
    SceneNavigator(threshold: threshold).step(position: position, direction: 1, scenes: scenes, chain: chain(items),
                                              atEdge: atEdge, verified: verified, mayVerify: mayVerify, seconds: seconds)
}
private func back(_ position: Int, _ items: [(Int, KeyframeLook)], scenes: Int = 1, atEdge: Bool = false,
                  verified: [Int: [Int]] = [:], threshold: Double = 25, mayVerify: Bool = true) -> SceneNavigator.Step {
    SceneNavigator(threshold: threshold).step(position: position, direction: -1, scenes: scenes, chain: chain(items),
                                              atEdge: atEdge, verified: verified, mayVerify: mayVerify, seconds: seconds)
}

@Suite struct SceneNavigatorTests {
    @Test func forwardFindsTheFirstCut() {
        #expect(forward(10, [(0, p(10)), (50, p(12)), (100, p(90)), (150, p(92))], verified: [100: [100]]) == .found(100))
    }

    @Test func forwardCutRightAfterK0() {
        #expect(forward(40, [(0, p(10)), (50, p(90))], verified: [50: [50]]) == .found(50))
    }

    @Test func forwardAsksForMoreWithoutACut() {
        #expect(forward(10, [(0, p(10)), (50, p(12))]) == .needNeighbour(of: 50, direction: 1))
    }

    @Test func forwardNoneAtTheEdge() {
        #expect(forward(10, [(0, p(10)), (50, p(12))], atEdge: true) == .none)
    }

    @Test func darkBetweenScenesLandsOnTheFirstPicture() {
        #expect(forward(10, [(0, p(10)), (50, .dark), (100, p(90))]) == .found(100))
    }

    @Test func darkInsideASceneIsNoCut() {
        #expect(forward(10, [(0, p(10)), (50, .dark), (100, p(12))], atEdge: true) == .none)
    }

    @Test func forwardFromDarkLandsOnTheFirstPicture() {
        #expect(forward(60, [(50, .dark), (100, p(90))]) == .found(100))
    }

    @Test func allDarkIsNone() {
        #expect(forward(10, [(0, .dark), (50, .dark)], atEdge: true) == .none)
        #expect(back(60, [(50, .dark), (0, .dark)], atEdge: true) == .none)
    }

    @Test func skipsSeveralScenes() {
        let items = [(0, p(10)), (50, p(90)), (100, p(170)), (150, p(250))]
        let verified = [50: [50], 100: [100], 150: [150]]
        #expect(forward(10, items, scenes: 2, verified: verified) == .found(100))
        #expect(forward(10, items, scenes: 5, atEdge: true, verified: verified) == .found(150))
    }

    @Test func backInsideASceneGoesToItsStart() {
        #expect(back(140, [(100, p(90)), (50, p(10)), (0, p(10))], verified: [100: [100]]) == .found(100))
    }

    @Test func backNearTheStartGoesToThePreviousScene() {
        #expect(back(110, [(100, p(90)), (50, p(10)), (0, p(12))], atEdge: true, verified: [100: [100]]) == .found(0))
    }

    @Test func backExactlyOnAStartGoesToThePreviousScene() {
        #expect(back(100, [(100, p(90)), (50, p(170)), (0, p(10))], atEdge: true, verified: [100: [100], 50: [50]]) == .found(50))
    }

    @Test func backAtTheFileStartIsNone() {
        #expect(back(10, [(0, p(10))], atEdge: true) == .none)
    }

    @Test func backAsksForMore() {
        #expect(back(140, [(100, p(90)), (50, p(92))]) == .needNeighbour(of: 50, direction: -1))
    }

    // MARK: - The hybrid: keyframe candidates checked frame by frame inside the GOP (threshold 45)

    @Test func candidateAsksForVerification() {
        #expect(forward(10, [(0, p(10)), (50, p(70))], threshold: 45) == .needVerification(from: 0, through: 50))
    }

    @Test func verifiedCutLandsOnTheExactFrame() {
        #expect(forward(10, [(0, p(10)), (50, p(70))], verified: [50: [37]], threshold: 45) == .found(37))
    }

    @Test func rejectedCandidateContinues() {
        // 60 apart: below the transition threshold, so camera motion.
        #expect(forward(10, [(0, p(10)), (50, p(70)), (100, p(72))], atEdge: true, verified: [50: []], threshold: 45) == .none)
    }

    @Test func transitionWithoutAHardCut() {
        #expect(forward(10, [(0, p(10)), (50, p(90))], verified: [50: []], threshold: 45) == .found(50))
    }

    @Test func darkBetweenNeedsNoVerification() {
        #expect(forward(10, [(0, p(10)), (50, .dark), (100, p(90))], threshold: 45) == .found(100))
    }

    @Test func twoCutsInOneGOP() {
        #expect(forward(10, [(0, p(10)), (50, p(70))], scenes: 2, verified: [50: [20, 37]], threshold: 45) == .found(37))
        #expect(forward(25, [(0, p(10)), (50, p(70))], verified: [50: [20, 37]], threshold: 45) == .found(37))
    }

    @Test func backwardUsesTheExactFrame() {
        #expect(back(140, [(100, p(90)), (50, p(10))], verified: [100: [80]], threshold: 45) == .found(80))
        // 85 is within 1 s of 80: the scene before.
        #expect(back(85, [(100, p(90)), (50, p(10)), (0, p(10))], atEdge: true, verified: [100: [80]], threshold: 45)
                == .found(0))
    }

    @Test func backwardTakesTheLastCutBeforeThePosition() {
        #expect(back(140, [(100, p(90)), (50, p(10))], verified: [100: [60, 80]], threshold: 45) == .found(80))
        #expect(back(140, [(100, p(90)), (50, p(10))], scenes: 2, verified: [100: [60, 80]], threshold: 45) == .found(60))
    }

    @Test func backwardAsksForVerification() {
        #expect(back(140, [(100, p(90)), (50, p(10))], threshold: 45) == .needVerification(from: 50, through: 100))
    }

    // Out of time for GOP checks: a candidate is judged by its keyframes alone.
    @Test func withoutChecksAStrongCandidateStartsAtItsKeyframe() {
        #expect(forward(10, [(0, p(10)), (50, p(90))], threshold: 45, mayVerify: false) == .found(50))
    }

    @Test func withoutChecksAWeakCandidateIsPassed() {
        #expect(forward(10, [(0, p(10)), (50, p(70)), (100, p(160))], threshold: 45, mayVerify: false) == .found(100))
    }

    @Test func withoutChecksAVerifiedCandidateKeepsItsCut() {
        #expect(forward(10, [(0, p(10)), (50, p(70))], verified: [50: [37]], threshold: 45, mayVerify: false) == .found(37))
    }

    @Test func withoutChecksBackward() {
        #expect(back(140, [(100, p(90)), (50, p(10))], threshold: 45, mayVerify: false) == .found(100))
    }
}
