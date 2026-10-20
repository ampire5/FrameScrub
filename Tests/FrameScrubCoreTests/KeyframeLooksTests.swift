import Foundation
import Testing
@testable import FrameScrubCore

/// scenes.mp4: 175 frames, keyframes every 25; scenes start at 0, 50 (black), 75 and 125.
@Suite struct KeyframeLooksTests {
    private func makeLooks(approximate: Bool = false, preferHardware: Bool = true) throws -> KeyframeLooks {
        let url = Fixtures.url(Fixtures.scenes)
        let source = try MediaSource(url: url)
        let index = approximate ? source.approximateIndex() : try MediaSource(url: url).buildIndex()
        #expect(index.isExact == !approximate)
        return try KeyframeLooks(url: url, index: index, rotationClockwise: 0, readCache: nil, preferHardware: preferHardware)
    }

    private func signature(_ look: KeyframeLook) -> SceneSignature? {
        if case .picture(let signature) = look { return signature }
        return nil
    }

    @Test func looksAtTheFixture() throws {
        let looks = try makeLooks()
        let first = try #require(signature(try looks.look(at: 0)))
        let bars = try #require(signature(try looks.look(at: 75)))
        let rgb = try #require(signature(try looks.look(at: 125)))
        #expect(first.difference(bars) >= 25)
        #expect(first.difference(rgb) >= 25)
        #expect(bars.difference(rgb) >= 25)
        #expect(try looks.look(at: 50) == .dark)
        let sameScene = try #require(signature(try looks.look(at: 25)))
        #expect(first.difference(sameScene) < 25)
    }

    @Test(arguments: [false, true], [false, true])
    func neighbours(approximate: Bool, preferHardware: Bool) throws {
        let looks = try makeLooks(approximate: approximate, preferHardware: preferHardware)
        #expect(try looks.neighbour(of: 0, direction: 1) == 25)
        #expect(try looks.neighbour(of: 125, direction: 1) == 150)
        #expect(try looks.neighbour(of: 150, direction: 1) == nil)
        #expect(try looks.neighbour(of: 25, direction: -1) == 0)
        #expect(try looks.neighbour(of: 0, direction: -1) == nil)
        #expect(try looks.keyframe(atOrBefore: 99) == 75)
        #expect(try looks.keyframe(atOrBefore: 0) == 0)
        #expect(try looks.keyframe(atOrBefore: 174) == 150)
    }

    @Test func cachesLooks() throws {
        let looks = try makeLooks()
        let first = try looks.look(at: 75)
        #expect(looks.cached.count == 1)
        #expect(try looks.look(at: 75) == first)
        #expect(looks.cached.count == 1)
    }

    /// Walks `neighbour` from the first keyframe with an approximate index and checks `look` decodes each keyframe itself.
    private func walkKeyframes(_ name: String, preferHardware: Bool = true) throws -> (found: [Int], exact: [Int]) {
        let url = Fixtures.url(name)
        let exact = try MediaSource(url: url).buildIndex()
        let approximate = try MediaSource(url: url).approximateIndex()
        #expect(!approximate.isExact)
        let looks = try KeyframeLooks(url: url, index: approximate, rotationClockwise: 0, readCache: nil,
                                      preferHardware: preferHardware)
        var found = [try looks.keyframe(atOrBefore: 0)]
        while let next = try looks.neighbour(of: found.last!, direction: 1) {
            found.append(next)
            if found.count > exact.keyframes.count + 1 { break }
        }
        for keyframe in found {
            _ = try looks.look(at: keyframe)
            #expect(looks.lastDecodedFrame == keyframe)
        }
        return (found, exact.keyframes)
    }

    @Test(arguments: [false, true])
    func looksDecodeTheRequestedKeyframeOfAMillisecondTimeBase(preferHardware: Bool) throws {
        let (found, exact) = try walkKeyframes(Fixtures.av1, preferHardware: preferHardware)   // 30 fps in 1/1000: inexact estimates
        #expect(found == exact)
    }

    @Test(arguments: [false, true])
    func openGOPLeadingPicturesAreNotTheKeyframe(preferHardware: Bool) throws {
        let (found, exact) = try walkKeyframes(Fixtures.hevc10, preferHardware: preferHardware)
        #expect(found == exact)
        #expect(exact.count > 1)
        let url = Fixtures.url(Fixtures.hevc10)
        let looks = try KeyframeLooks(url: url, index: try MediaSource(url: url).buildIndex(), rotationClockwise: 0,
                                      readCache: nil, preferHardware: preferHardware)
        for keyframe in exact {
            _ = try looks.look(at: keyframe)
            #expect(looks.lastDecodedFrame == keyframe)
        }
    }

    @Test(arguments: [false, true])
    func anEstimateBelowTheKeyframeStillLooksAtIt(preferHardware: Bool) throws {
        let url = Fixtures.url(Fixtures.av1)
        let exact = try MediaSource(url: url).buildIndex()
        let honest = try MediaSource(url: url).approximateIndex()
        // Three ticks (ms) early: what a 30 fps file in a 1/1000 time base does to some frames.
        let early = FrameIndex.approximate(startPTS: honest.zeroPTS - 3, ticksPerFrame: 1 / (30 * honest.timeBase),
                                           frameCount: honest.frameCount, timeBase: honest.timeBase)
        let looks = try KeyframeLooks(url: url, index: early, rotationClockwise: 0, readCache: nil, preferHardware: preferHardware)
        let keyframe = try #require(exact.keyframes.last)
        #expect(keyframe > 0)
        _ = try looks.look(at: keyframe)
        #expect(looks.lastDecodedFrame == keyframe)
    }

    /// Every keyframe of the exact index, looked at with an exact and with an approximate index.
    @Test(arguments: [Fixtures.editList, Fixtures.h264], [false, true])
    func looksAtEveryKeyframeWithAnEditListAndBFrames(name: String, preferHardware: Bool) throws {
        let url = Fixtures.url(name)
        let exact = try MediaSource(url: url).buildIndex()
        for index in [exact, try MediaSource(url: url).approximateIndex()] {
            let looks = try KeyframeLooks(url: url, index: index, rotationClockwise: 0, readCache: nil, preferHardware: preferHardware)
            var walked = [try looks.keyframe(atOrBefore: 0)]
            while let next = try looks.neighbour(of: walked.last!, direction: 1) { walked.append(next) }
            #expect(walked == exact.keyframes)
            for keyframe in exact.keyframes {
                _ = try looks.look(at: keyframe)
                #expect(looks.lastDecodedFrame == keyframe)
                // Just past a keyframe the demuxer may still file it ahead of that position.
                for offset in 0...3 { #expect(try looks.keyframe(atOrBefore: keyframe + offset) == keyframe) }
            }
        }
    }

    // MARK: - Cuts inside a GOP

    private func makeLooks(_ name: String, approximate: Bool, preferHardware: Bool) throws -> KeyframeLooks {
        let url = Fixtures.url(name)
        let index = approximate ? try MediaSource(url: url).approximateIndex() : try MediaSource(url: url).buildIndex()
        return try KeyframeLooks(url: url, index: index, rotationClockwise: 0, readCache: nil, preferHardware: preferHardware)
    }

    /// scenes_midgop.mp4: keyframes 0, 50, 100; the cut at 60. scenes.mp4: the cut at 125 is a keyframe.
    @Test(arguments: [false, true], [false, true])
    func cutsInsideAGOP(approximate: Bool, preferHardware: Bool) throws {
        let midGOP = try makeLooks(Fixtures.scenesMidGOP, approximate: approximate, preferHardware: preferHardware)
        #expect(try midGOP.cuts(from: 50, through: 100, isCancelled: { false }) == [60])
        #expect(midGOP.lastCheckedFrames == 50...100)
        #expect(try midGOP.cuts(from: 0, through: 50, isCancelled: { false }) == [])
        #expect(midGOP.lastCheckedFrames == 0...50)
        let scenes = try makeLooks(Fixtures.scenes, approximate: approximate, preferHardware: preferHardware)
        #expect(try scenes.cuts(from: 100, through: 125, isCancelled: { false }) == [125])
        #expect(scenes.lastCheckedFrames == 100...125)
    }

    @Test func cutsThrowWhenCancelled() throws {
        let looks = try makeLooks(Fixtures.scenesMidGOP, approximate: false, preferHardware: true)
        var checks = 0
        #expect(throws: CancellationError.self) {
            _ = try looks.cuts(from: 50, through: 100, isCancelled: { checks += 1; return checks > 5 })
        }
        #expect(checks == 6)
    }

    /// An edit list with B-frames: the check starts on the keyframe itself, not the one before.
    @Test(arguments: [false, true], [false, true])
    func cutsStartOnTheKeyframeWithAnEditList(approximate: Bool, preferHardware: Bool) throws {
        let exact = try MediaSource(url: Fixtures.url(Fixtures.editList)).buildIndex()
        let looks = try makeLooks(Fixtures.editList, approximate: approximate, preferHardware: preferHardware)
        let keyframe = try #require(exact.keyframes.dropFirst().first)
        #expect(try looks.cuts(from: keyframe, through: keyframe + 10, isCancelled: { false }) == [])
        #expect(looks.lastCheckedFrames == keyframe...(keyframe + 10))
    }
}
