import CoreGraphics
import Testing
@testable import FrameScrubCore

@Suite struct OutputSizeTests {
    private let hd = CGSize(width: 1920, height: 1080)
    private let portrait = CGSize(width: 1080, height: 1920)
    private let screen6K = CGSize(width: 6144, height: 3456)

    @Test func parsesAndFormatsEveryForm() {
        for (text, size) in [("1", OutputSize.scale(1)), ("2", .scale(2)), ("4", .scale(4)), ("fit", .fitScreen),
                             ("width:3840", .width(3840)), ("height:2160", .height(2160))] {
            #expect(OutputSize(text: text) == size, "\(text)")
            #expect(size.text == text)
        }
        #expect(OutputSize(text: " FIT ") == .fitScreen)
        #expect(OutputSize(text: "Width:960") == .width(960))
    }

    @Test func rejectsBadValues() {
        for text in ["3", "0", "8", "fit:2", "width", "width:", "width:15", "width:16385", "height:-5", "width:1.5", "x2", ""] {
            #expect(OutputSize(text: text) == nil, "\(text)")
        }
    }

    @Test func integerLiteralMeansScale() {
        let size: OutputSize = 2
        #expect(size == .scale(2))
    }

    @Test func scaleMultipliesBothSides() {
        #expect(OutputSize.scale(1).targetSize(source: hd, screen: nil) == hd)
        #expect(OutputSize.scale(2).targetSize(source: hd, screen: nil) == CGSize(width: 3840, height: 2160))
        #expect(OutputSize.scale(4).targetSize(source: hd, screen: nil) == CGSize(width: 7680, height: 4320))
    }

    @Test func fitScreenKeepsTheAspectRatioInBothDirections() {
        #expect(OutputSize.fitScreen.targetSize(source: hd, screen: screen6K) == screen6K)                 // up
        #expect(OutputSize.fitScreen.targetSize(source: portrait, screen: screen6K) == CGSize(width: 1944, height: 3456))
        let uhd = CGSize(width: 7680, height: 4320)
        #expect(OutputSize.fitScreen.targetSize(source: uhd, screen: screen6K) == screen6K)                // down
        let wide = CGSize(width: 2000, height: 500)
        #expect(OutputSize.fitScreen.targetSize(source: wide, screen: screen6K) == CGSize(width: 6144, height: 1536))
    }

    @Test func fitScreenWithoutAScreenHasNoTarget() {
        #expect(OutputSize.fitScreen.targetSize(source: hd, screen: nil) == nil)
        #expect(OutputSize.fitScreen.targetSize(source: hd, screen: .zero) == nil)
    }

    @Test func widthAndHeightFixOneSide() {
        #expect(OutputSize.width(3840).targetSize(source: hd, screen: nil) == CGSize(width: 3840, height: 2160))
        #expect(OutputSize.width(960).targetSize(source: hd, screen: nil) == CGSize(width: 960, height: 540))
        #expect(OutputSize.height(2160).targetSize(source: hd, screen: nil) == CGSize(width: 3840, height: 2160))
        #expect(OutputSize.height(1000).targetSize(source: portrait, screen: nil) == CGSize(width: 563, height: 1000))
    }

    @Test func theLongSideNeverExceedsTheSideLimit() {
        let target = OutputSize.scale(4).targetSize(source: CGSize(width: 7680, height: 4320), screen: nil)!
        #expect(max(target.width, target.height) == 16384)
        #expect(target == CGSize(width: 16384, height: 9216))
        let tall = OutputSize.height(16384).targetSize(source: CGSize(width: 1000, height: 100), screen: nil)!
        #expect(max(tall.width, tall.height) <= 16384)
    }

    @Test func suffixNamesTheResult() {
        #expect(OutputSize.scale(1).suffix(source: hd, target: hd) == "")
        #expect(OutputSize.scale(2).suffix(source: hd, target: CGSize(width: 3840, height: 2160)) == "_x2")
        #expect(OutputSize.fitScreen.suffix(source: hd, target: screen6K) == "_6144x3456")
        #expect(OutputSize.width(960).suffix(source: hd, target: CGSize(width: 960, height: 540)) == "_960x540")
        #expect(OutputSize.width(1920).suffix(source: hd, target: hd) == "")    // nothing changed
    }

    @Test func suffixUsesTheSizeWhenTheCapShrankAFactor() {
        let k8 = CGSize(width: 7680, height: 4320)
        #expect(OutputSize.scale(4).suffix(source: k8, target: CGSize(width: 16384, height: 9216)) == "_16384x9216")
        #expect(OutputSize.scale(2).suffix(source: k8, target: CGSize(width: 15360, height: 8640)) == "_x2")
        #expect(OutputSize.scale(4).suffix(source: hd, target: CGSize(width: 7680, height: 4320)) == "_x4")
    }
}
