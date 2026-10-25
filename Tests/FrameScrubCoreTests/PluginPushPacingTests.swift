import Testing
@testable import FrameScrubCore

@Suite("PluginPushPacing")
struct PluginPushPacingTests {
    private func due(_ pacing: inout PluginPushPacing, shown: Bool, _ now: Double, force: Bool = false) -> Bool {
        pacing.due(shown: shown, now: now, force: force)
    }

    @Test("a page whose slot is shown hears the state ten times a second")
    func shownRate() {
        var pacing = PluginPushPacing()
        #expect(due(&pacing, shown: true, 10))
        #expect(!due(&pacing, shown: true, 10.05))
        #expect(due(&pacing, shown: true, 10.11))
    }

    @Test("a page whose slot is hidden still hears it, four times a second at most")
    func hiddenRate() {
        var pacing = PluginPushPacing()
        #expect(due(&pacing, shown: false, 10))
        #expect(!due(&pacing, shown: false, 10.2))
        #expect(due(&pacing, shown: false, 10.26))
    }

    @Test("the two kinds of page keep their own clocks")
    func independent() {
        var pacing = PluginPushPacing()
        #expect(due(&pacing, shown: true, 5))
        #expect(due(&pacing, shown: false, 5.01))
        #expect(!due(&pacing, shown: true, 5.05))
        #expect(!due(&pacing, shown: false, 5.1))
    }

    @Test("a state change goes out at once, and starts the next interval")
    func force() {
        var pacing = PluginPushPacing()
        #expect(due(&pacing, shown: false, 1))
        #expect(due(&pacing, shown: false, 1.01, force: true))
        #expect(!due(&pacing, shown: false, 1.2))
        #expect(due(&pacing, shown: false, 1.27))
    }
}
