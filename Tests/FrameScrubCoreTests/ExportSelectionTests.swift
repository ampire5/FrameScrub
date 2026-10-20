import Testing
@testable import FrameScrubCore

@Suite struct ExportSelectionTests {
    private let cfr = FrameIndex(pts: (0..<600).map { Int64($0) * 512 }, keyframePTS: [0], timeBase: 1.0 / 15360)

    @Test func allAndEveryN() {
        #expect(ExportSelection.all.frames(in: 10...14, index: cfr) == [10, 11, 12, 13, 14])
        #expect(ExportSelection.every(10).frames(in: 100...129, index: cfr) == [100, 110, 120])
        #expect(ExportSelection.every(50).frames(in: 100...129, index: cfr) == [100])
    }

    @Test func perSecondOnConstantFrameRate() {
        let frames = ExportSelection.perSecond(10).frames(in: 0...59, index: cfr)
        #expect(frames == Array(stride(from: 0, through: 57, by: 3)))
    }

    @Test func perSecondFollowsVariableFrameRate() throws {
        let index = try MediaSource(url: Fixtures.url(Fixtures.vfr)).buildIndex()
        let frames = ExportSelection.perSecond(30).frames(in: 0...119, index: index)
        #expect(frames.count == 90)
        #expect(Array(frames.prefix(60)) == Array(0..<60))                     // 30 fps part: every frame
        #expect(Array(frames.suffix(30)) == Array(stride(from: 60, through: 118, by: 2)))   // 60 fps part: every other
    }

    @Test func infiniteRateSelectsNothing() {
        #expect(ExportSelection.perSecond(.infinity).frames(in: 0...59, index: cfr).isEmpty)
    }

    @Test func zeroRateSelectsNothing() {
        #expect(ExportSelection.perSecond(0).frames(in: 0...59, index: cfr).isEmpty)
    }

    @Test func buildsFromConfig() {
        var config = Config()
        #expect(ExportSelection(config: config) == .all)
        config.exportMode = .every
        config.exportEvery = 5
        #expect(ExportSelection(config: config) == .every(5))
        config.exportMode = .fps
        config.exportFPS = 2.5
        #expect(ExportSelection(config: config) == .perSecond(2.5))
    }

    @Test func windowsOfAllAndEveryN() {
        #expect(ExportSelection.all.windows(in: 10...12, index: cfr) == [10...10, 11...11, 12...12])
        #expect(ExportSelection.every(10).windows(in: 100...125, index: cfr) == [100...109, 110...119, 120...125])
        #expect(ExportSelection.every(50).windows(in: 100...129, index: cfr) == [100...129])
    }

    @Test func windowsPerSecondStartAtTheSelectedFrames() {
        let windows = ExportSelection.perSecond(10).windows(in: 0...59, index: cfr)
        #expect(windows.count == 20)
        #expect(windows.first == 0...2)
        #expect(windows.last == 57...59)
    }

    @Test func windowsFollowVariableFrameRate() throws {
        let index = try MediaSource(url: Fixtures.url(Fixtures.vfr)).buildIndex()
        let windows = ExportSelection.perSecond(30).windows(in: 0...119, index: index)
        #expect(windows.count == 90)
        #expect(windows[59] == 59...59)        // 30 fps part: one frame per window
        #expect(windows[60] == 60...61)        // 60 fps part: two
        #expect(windows.last == 118...119)
    }

    @Test func windowsCoverTheRangeAndMatchTheSelectedCount() {
        for selection in [ExportSelection.all, .every(7), .perSecond(4)] {
            let windows = selection.windows(in: 3...200, index: cfr)
            #expect(windows.flatMap { Array($0) } == Array(3...200), "\(selection)")
            #expect(windows.map(\.lowerBound) == selection.frames(in: 3...200, index: cfr), "\(selection)")
        }
        #expect(ExportSelection.perSecond(0).windows(in: 0...59, index: cfr).isEmpty)
    }
}
