import CoreGraphics
import Testing
@testable import FrameScrubCore

@Suite struct ExportEstimateTests {
    private let hd = CGSize(width: 1920, height: 1080)

    @Test func theNetworkEstimateScalesWithFramesAndMegapixels() throws {
        let one = try #require(ExportEstimate.mlSeconds(frames: 10, source: hd, output: 4, screen: nil, upscaler: .ml, hdr: false))
        #expect(abs(one - 10 * 2.0736 * ExportEstimate.secondsPerMegapixel) < 1e-9)
        let twice = try #require(ExportEstimate.mlSeconds(frames: 20, source: hd, output: 4, screen: nil, upscaler: .ml, hdr: false))
        #expect(abs(twice - 2 * one) < 1e-9)
    }

    @Test func noEstimateWhenTheNetworkIsNotUsed() {
        #expect(ExportEstimate.mlSeconds(frames: 10, source: hd, output: 4, screen: nil, upscaler: .lanczos, hdr: false) == nil)
        #expect(ExportEstimate.mlSeconds(frames: 10, source: hd, output: 4, screen: nil, upscaler: .ml, hdr: true) == nil)
        #expect(ExportEstimate.mlSeconds(frames: 10, source: CGSize(width: 3840, height: 2160), output: 2, screen: nil, upscaler: .ml, hdr: false) == nil)
        #expect(ExportEstimate.mlSeconds(frames: 10, source: hd, output: 1, screen: nil, upscaler: .ml, hdr: false) == nil)
        #expect(ExportEstimate.mlSeconds(frames: 10, source: hd, output: .width(2000), screen: nil, upscaler: .ml, hdr: false) == nil)   // below 1.5x
        #expect(ExportEstimate.mlSeconds(frames: 10, source: hd, output: .width(960), screen: nil, upscaler: .ml, hdr: false) == nil)     // reduction
        #expect(ExportEstimate.mlSeconds(frames: 10, source: hd, output: .fitScreen, screen: nil, upscaler: .ml, hdr: false) == nil)      // unknown screen
        #expect(ExportEstimate.mlSeconds(frames: 0, source: hd, output: 4, screen: nil, upscaler: .ml, hdr: false) == nil)
    }

    @Test func fitScreenUsesTheScreenToDecideWhetherTheNetworkRuns() {
        let screen = CGSize(width: 6144, height: 3456)
        #expect(ExportEstimate.mlSeconds(frames: 5, source: hd, output: .fitScreen, screen: screen, upscaler: .ml, hdr: false) != nil)
        #expect(ExportEstimate.mlSeconds(frames: 5, source: hd, output: .fitScreen, screen: CGSize(width: 2000, height: 1125), upscaler: .ml, hdr: false) == nil)
    }

    @Test func textIsHumanReadable() {
        #expect(ExportEstimate.text(seconds: 0.4) == "under 1 s")
        #expect(ExportEstimate.text(seconds: 12.4) == "about 12 s")
        #expect(ExportEstimate.text(seconds: 59.6) == "about 1 min")
        #expect(ExportEstimate.text(seconds: 200) == "about 3 min")
        #expect(ExportEstimate.text(seconds: 7300) == "about 2 h")
    }
}
