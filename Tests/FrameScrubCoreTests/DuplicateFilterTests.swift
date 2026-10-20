import CoreImage
import Foundation
import Testing
@testable import FrameScrubCore

/// A dark frame with a bright block covering `columns` of 16 columns from the left.
private func frame(brightColumns columns: Int) -> SceneSignature {
    let dark = CIImage(color: CIColor(red: 0.1, green: 0.1, blue: 0.1)).cropped(to: CGRect(x: 0, y: 0, width: 640, height: 360))
    let bright = CIImage(color: CIColor(red: 0.9, green: 0.9, blue: 0.9)).cropped(to: CGRect(x: 0, y: 0, width: 40 * columns, height: 360))
    return .of(bright.composited(over: dark))
}

@Suite struct DuplicateFilterTests {
    @Test func theFirstFrameIsSaved() {
        var filter = DuplicateFilter(minimumChange: 0.5)
        let kept = filter.keeps(frame(brightColumns: 0))
        #expect(kept)
    }

    @Test func aRepeatedPictureIsSkipped() {
        var filter = DuplicateFilter(minimumChange: 0.05)
        let first = filter.keeps(frame(brightColumns: 4)), again = filter.keeps(frame(brightColumns: 4))
        #expect(first && !again)
    }

    /// Each step changes 1/16 of the picture: under 10 % from the previous frame, but it adds up from the last saved one.
    @Test func aSlowDriftIsMeasuredFromTheLastSavedFrame() {
        var filter = DuplicateFilter(minimumChange: 0.10)
        let kept = (0...8).map { filter.keeps(frame(brightColumns: $0)) }
        #expect(kept == [true, false, true, false, true, false, true, false, true])
    }

    @Test func changeIsAPercentOfThePicture() {
        #expect(abs(DuplicateFilter.change(frame(brightColumns: 0), frame(brightColumns: 8)) - 50) <= 4)   // plus the blurred edge column
    }
}
