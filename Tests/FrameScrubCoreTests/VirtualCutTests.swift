import Foundation
import Testing
@testable import FrameScrubCore

@Suite struct VirtualCutTests {
    private func stateResult(_ value: Bool) -> Bool { value }

    private let a = VirtualCutSource(kind: .scene, locator: "1", version: "original")
    private let b = VirtualCutSource(kind: .scene, locator: "2", version: "original")

    private func range(_ id: String, _ source: VirtualCutSource, _ start: Double, _ end: Double) -> VirtualCutRange {
        VirtualCutRange(id: id, source: source, start: start, end: end)
    }

    @Test func unionsTransitiveOverlapsAtTheirFirstAuthoredPosition() throws {
        let timeline = try #require(VirtualCutTimeline(ranges: [
            range("a", a, 10, 20), range("b", b, 0, 3),
            range("c", a, 23, 25), range("d", a, 18, 24)
        ]))
        #expect(timeline.spans.count == 2)
        #expect(timeline.spans.first?.sourceStart == 10)
        #expect(timeline.spans.first?.sourceEnd == 25)
        #expect(timeline.duration == 18)
        #expect(timeline.location(at: 0)?.sourceTime == 10)
        #expect(timeline.location(at: 14.5)?.sourceTime == 24.5)
        #expect(timeline.location(at: 15)?.spanIndex == 1)
        #expect(timeline.location(at: 15)?.sourceTime == 0)
        #expect(timeline.location(at: 18)?.sourceTime == 3.0.nextDown)
    }

    @Test func touchingRangesAndDifferentVersionsStaySeparate() throws {
        let otherVersion = VirtualCutSource(kind: .scene, locator: "1", version: "replacement")
        let timeline = try #require(VirtualCutTimeline(ranges: [
            range("a", a, 0, 5), range("b", a, 5, 10), range("c", otherVersion, 4, 6)
        ]))
        #expect(timeline.spans.count == 3)
        #expect(timeline.duration == 12)
        #expect(timeline.location(at: 10)?.spanIndex == 2)
    }

    @Test func resumeTracksTheAuthoredRangeThroughReordering() throws {
        let first = range("a", a, 10, 20)
        let second = range("b", b, 2, 5)
        let original = try #require(VirtualCutTimeline(ranges: [first, second]))
        let anchor = try #require(original.anchor(at: 11))
        let reordered = try #require(VirtualCutTimeline(ranges: [second, first]))
        let removed = try #require(VirtualCutTimeline(ranges: [first]))
        #expect(reordered.resume(at: anchor) == 1)
        #expect(removed.resume(at: anchor) == 0)
    }

    @Test func rejectsInvalidAndAmbiguousPayloads() {
        #expect(VirtualCutTimeline(ranges: []) == nil)
        #expect(VirtualCutTimeline(ranges: [range("a", a, .nan, 2)]) == nil)
        #expect(VirtualCutTimeline(ranges: [range("a", a, -1, 2)]) == nil)
        #expect(VirtualCutTimeline(ranges: [range("a", a, 2, 2)]) == nil)
        #expect(VirtualCutTimeline(ranges: [range("a", a, 1, 2), range("a", b, 3, 4)]) == nil)
        let excess = (0...2_000).map { range(String($0), a, 0, 1) }
        #expect(VirtualCutTimeline(ranges: excess) == nil)
    }
}

extension VirtualCutTests {
    @Test func ignoresAnOpenThatWasReplacedByAnotherSeek() throws {
        let timeline = try #require(VirtualCutTimeline(ranges: [
            range("a", a, 1, 3), range("b", b, 10, 14), range("c", a, 6, 9)
        ]))
        var state = VirtualCutPlayback(timeline: timeline)
        let firstRequest = state.seek(0, playing: true)
        let first = try #require(firstRequest)
        #expect((stateResult(state.opened(first))))
        let secondRequest = state.advance(1)
        let second = try #require(secondRequest)
        #expect(second.location.sourceTime == 10)
        let thirdRequest = state.seek(7, playing: false)
        let third = try #require(thirdRequest)
        #expect(third.location.sourceTime == 7)
        #expect(!(stateResult(state.opened(second))))
        #expect((stateResult(state.opened(third))))
        #expect(!state.wantsPlayback)
    }

    @Test func failedOpenCanRetryOrSkipAndOnlyWrapsWhenLooping() throws {
        let timeline = try #require(VirtualCutTimeline(ranges: [
            range("a", a, 1, 3), range("b", b, 10, 14), range("c", a, 6, 9)
        ]))
        var state = VirtualCutPlayback(timeline: timeline)
        let firstRequest = state.seek(0, playing: true)
        let first = try #require(firstRequest)
        #expect((stateResult(state.opened(first))))
        let secondRequest = state.advance(1)
        let second = try #require(secondRequest)
        #expect((stateResult(state.failed(second))))
        let retryRequest = state.retry()
        let retry = try #require(retryRequest)
        #expect(retry.location == second.location)
        #expect(!(stateResult(state.opened(second))))
        #expect((stateResult(state.failed(retry))))
        let skippedRequest = state.advance(1)
        let skipped = try #require(skippedRequest)
        #expect(skipped.location.sourceTime == 6)
        #expect((stateResult(state.opened(skipped))))
        let end = state.advance(1)
        #expect(end == nil)
        #expect(!state.wantsPlayback)
        state.loops = true
        state.wantsPlayback = true
        let wrapped = state.advance(1)
        #expect(wrapped?.location.sourceTime == 1)
    }
}

extension VirtualCutTests {
    @Test func onlyConfiguredSameOriginCanRegisterACatalog() throws {
        let origin = try #require(PluginOrigin(url: URL(string: "https://example.com/editor")!))
        let other = try #require(PluginOrigin(url: URL(string: "https://elsewhere.example/editor")!))
        let catalog = try #require(PluginCutCatalog(id: "cuts", title: "Cuts",
                                                    endpoint: URL(string: "https://example.com/catalog")!))
        #expect(catalog.allowed(from: origin, configured: [origin]))
        #expect(!catalog.allowed(from: origin, configured: []))
        #expect(!catalog.allowed(from: other, configured: [origin, other]))
    }

    @Test func endOfVariableRateSpanExcludesFrameExactlyAtBoundary() {
        let index = FrameIndex(pts: [0, 1, 3, 5, 6], keyframePTS: [0], timeBase: 0.1)
        #expect(index.frameNumber(before: 0.5) == 2)
        #expect(index.frameNumber(before: 0.55) == 3)
    }
}

extension VirtualCutTests {
    @Test func onlyAContinuousSeekNeedingANewSourceWaits() throws {
        let timeline = try #require(VirtualCutTimeline(ranges: [
            range("a", a, 1, 3), range("b", b, 10, 14)
        ]))
        var state = VirtualCutPlayback(timeline: timeline)
        let across = state.seek(2.5, playing: false)
        let target = try #require(across)
        #expect(state.shouldDeferOpen(target, continuous: true, loaded: a, opening: nil))
        #expect(!state.shouldDeferOpen(target, continuous: false, loaded: a, opening: nil))
        #expect(!state.shouldDeferOpen(target, continuous: true, loaded: a, opening: b))

        let back = state.seek(0.5, playing: false)
        let latest = try #require(back)
        #expect(!state.shouldDeferOpen(latest, continuous: true, loaded: a, opening: nil))
        #expect(!stateResult(state.opened(target)))
        #expect(stateResult(state.opened(latest)))
    }
}
