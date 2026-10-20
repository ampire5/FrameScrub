import CoreGraphics
import Testing
@testable import FrameScrubCore

@Suite struct WindowSizingTests {
    private let hd = CGSize(width: 1920, height: 1080)
    private let available = CGSize(width: 1500, height: 900)

    private func size(_ request: WindowSizing.Request, video: CGSize? = nil, backing: Double = 2,
                      available: CGSize? = nil) -> WindowSizing.Result {
        WindowSizing.contentSize(for: request, video: video ?? hd, backingScale: backing, available: available ?? self.available)
    }

    @Test func oneHundredPercentIsOneVideoPixelPerPhysicalPixel() {
        #expect(size(.scale(1)) == WindowSizing.Result(size: CGSize(width: 960, height: 540), fittedPercent: nil))
        #expect(size(.scale(1), backing: 1, available: CGSize(width: 2000, height: 1200)).size == hd)
        #expect(size(.scale(0.5)).size == CGSize(width: 480, height: 270))
    }

    @Test func aSizeThatDoesNotFitIsFittedAndReported() {
        let result = size(.scale(2))                    // 1920x1080 points wanted, 1500x900 available
        #expect(result.size == CGSize(width: 1500, height: 844))
        #expect(result.fittedPercent == 156)
    }

    @Test func aNewShapeKeepsTheHeightUnlessTooWide() {
        #expect(size(.keepHeight(540), video: CGSize(width: 1024, height: 400)).size == CGSize(width: 1382, height: 540))
        #expect(size(.keepHeight(540), video: CGSize(width: 1920, height: 1440)).size == CGSize(width: 720, height: 540))
        let wide = size(.keepHeight(800), video: CGSize(width: 2350, height: 1000))   // 1880 points wide: fitted to 1500
        #expect(wide.size == CGSize(width: 1500, height: 638))
        #expect(wide.fittedPercent == nil)
    }

    @Test func fitScreenFillsTheAvailableAreaKeepingTheAspect() {
        let result = size(.fitScreen)
        #expect(result.size == CGSize(width: 1500, height: 844))
        #expect(result.fittedPercent == 156)
        let portrait = size(.fitScreen, video: CGSize(width: 1080, height: 1920))
        #expect(portrait.size == CGSize(width: 506, height: 900))
    }

    @Test func theInitialSizeIs100PercentWhenItFitsElse85PercentOfTheScreen() {
        #expect(size(.initial).size == CGSize(width: 960, height: 540))                  // fits: natural size, not bigger
        let exact = size(.initial, available: CGSize(width: 960, height: 600))          // fits exactly: still 100 %
        #expect(exact.size == CGSize(width: 960, height: 540))
        let small = size(.initial, available: CGSize(width: 900, height: 600))          // does not fit: 0.85 of the width
        #expect(small.size == CGSize(width: 765, height: 430))
        #expect(small.fittedPercent == nil)
    }

    @Test func aSourceSmallerThanTheScreenIsNeverEnlargedOnOpen() {
        let tiny = size(.initial, video: CGSize(width: 640, height: 360), backing: 1, available: CGSize(width: 3000, height: 2000))
        #expect(tiny.size == CGSize(width: 640, height: 360))
    }

    // MARK: Placement

    private let main = CGRect(x: 0, y: 0, width: 1500, height: 900)
    private let right = CGRect(x: 1500, y: 100, width: 1000, height: 700)

    private func origin(_ size: CGSize, center: CGPoint?) -> CGPoint {
        WindowPlacement.origin(size: size, center: center, screens: [main, right], main: main)
    }

    @Test func theWindowIsCenteredOnTheRememberedPoint() {
        #expect(origin(CGSize(width: 400, height: 200), center: CGPoint(x: 700, y: 500)) == CGPoint(x: 500, y: 400))
        #expect(origin(CGSize(width: 400, height: 200), center: CGPoint(x: 2000, y: 450)) == CGPoint(x: 1800, y: 350))
    }

    @Test func aWindowThatWouldStickOutIsMovedOntoItsScreen() {
        #expect(origin(CGSize(width: 400, height: 200), center: CGPoint(x: 1450, y: 880)) == CGPoint(x: 1100, y: 700))
        // Larger than the screen: top-left corner stays visible.
        #expect(origin(CGSize(width: 1200, height: 800), center: CGPoint(x: 2000, y: 450)) == CGPoint(x: 1500, y: 0))
    }

    @Test func withoutAUsableCenterTheWindowGoesToTheMiddleOfTheMainScreen() {
        #expect(origin(CGSize(width: 400, height: 200), center: nil) == CGPoint(x: 550, y: 350))
        // The remembered screen is gone.
        #expect(origin(CGSize(width: 400, height: 200), center: CGPoint(x: -800, y: 300)) == CGPoint(x: 550, y: 350))
    }

    // MARK: Remembered frame

    private func frame(_ saved: CGRect?) -> CGRect {
        WindowPlacement.frame(saved: saved, fallbackSize: CGSize(width: 960, height: 540), screens: [main, right], main: main)
    }

    @Test func theRememberedFrameIsUsedAsItWas() {
        #expect(frame(CGRect(x: 100, y: 50, width: 1200, height: 700)) == CGRect(x: 100, y: 50, width: 1200, height: 700))
        #expect(frame(CGRect(x: 1600, y: 200, width: 800, height: 450)) == CGRect(x: 1600, y: 200, width: 800, height: 450))
    }

    @Test func aFrameLargerThanItsScreenShrinksOntoIt() {
        // The right screen is 1000 x 700: the frame is cut to it and moved inside.
        #expect(frame(CGRect(x: 1700, y: 300, width: 1400, height: 900)) == CGRect(x: 1500, y: 100, width: 1000, height: 700))
    }

    @Test func aFrameOnAScreenThatIsGoneMovesToTheMainScreen() {
        #expect(frame(CGRect(x: -2000, y: 100, width: 800, height: 400)) == CGRect(x: 350, y: 250, width: 800, height: 400))
    }

    @Test func withoutARememberedFrameTheFallbackSizeIsCentred() {
        #expect(frame(nil) == CGRect(x: 270, y: 180, width: 960, height: 540))
    }
}
