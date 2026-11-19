import Testing
@testable import FrameScrubCore

@Suite struct VideoClickTests {
    @Test func forceClickFiresOnceUntilRelease() {
        var click = VideoClick()
        click.begin(count: 1)
        #expect(click.pressure(stage: 1) == false)
        #expect(click.pressure(stage: 2) == true)
        #expect(click.pressure(stage: 2) == false)
        #expect(click.pressure(stage: 1) == false)
        #expect(click.pressure(stage: 2) == false)
        #expect(click.end() == nil)
        #expect(click.pressure(stage: 0) == false)
        #expect(click.pressure(stage: 2) == true)
    }

    @Test func forceClickOrDragDoesNotCompleteADoubleClick() {
        var click = VideoClick()
        click.begin(count: 1)
        #expect(click.pressure(stage: 2) == true)
        #expect(click.pressure(stage: 0) == false)
        #expect(click.end() == nil)
        click.begin(count: 2)
        #expect(click.end() == nil)

        click.begin(count: 1)
        #expect(click.end() == 1)
        click.begin(count: 2)
        #expect(click.pressure(stage: 2) == true)
        #expect(click.end() == nil)
        #expect(click.pressure(stage: 0) == false)

        click.begin(count: 1)
        #expect(click.end() == 1)
        click.begin(count: 2)
        click.drag()
        #expect(click.end() == nil)

        click.begin(count: 1)
        #expect(click.end() == 1)
        click.begin(count: 2)
        #expect(click.end() == 2)
    }
}
