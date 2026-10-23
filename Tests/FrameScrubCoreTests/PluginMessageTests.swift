import Foundation
import Testing
@testable import FrameScrubCore

@Suite struct PluginMessageTests {
    private func message(_ json: [String: Any]) -> PluginMessage? { PluginMessage(json: json) }

    @Test func simpleCommands() {
        #expect(message(["cmd": "play"]) == .play)
        #expect(message(["cmd": "pause"]) == .pause)
        #expect(message(["cmd": "focusPlayer"]) == .focusPlayer)
        #expect(message(["cmd": "play", "extra": 1]) == .play)   // unknown arguments are ignored
    }

    @Test func seekNeedsAFiniteNonNegativeTime() {
        #expect(message(["cmd": "seek", "t": 12.5]) == .seek(12.5))
        #expect(message(["cmd": "seek", "t": 0]) == .seek(0))
        #expect(message(["cmd": "seek", "t": 3 as Int]) == .seek(3))
        #expect(message(["cmd": "seek"]) == nil)
        #expect(message(["cmd": "seek", "t": "12"]) == nil)
        #expect(message(["cmd": "seek", "t": -1]) == nil)
        #expect(message(["cmd": "seek", "t": Double.nan]) == nil)
        #expect(message(["cmd": "seek", "t": Double.infinity]) == nil)
    }

    @Test func stepNeedsAFrameCount() {
        #expect(message(["cmd": "step", "n": 1]) == .step(1))
        #expect(message(["cmd": "step", "n": -5]) == .step(-5))
        #expect(message(["cmd": "step", "n": 2.0]) == .step(2))
        #expect(message(["cmd": "step"]) == nil)
        #expect(message(["cmd": "step", "n": "1"]) == nil)
        #expect(message(["cmd": "step", "n": Double.infinity]) == nil)
    }

    @Test func loopIsASegmentOrNothing() {
        #expect(message(["cmd": "loop", "a": 1, "b": 2.5]) == .loop(1...2.5))
        #expect(message(["cmd": "loop"]) == .loop(nil))
        #expect(message(["cmd": "loop", "a": 2, "b": 2]) == nil)
        #expect(message(["cmd": "loop", "a": 3, "b": 1]) == nil)
        #expect(message(["cmd": "loop", "a": 1]) == nil)
        #expect(message(["cmd": "loop", "a": "1", "b": 2]) == nil)
        #expect(message(["cmd": "loop", "a": -1, "b": 2]) == nil)
    }

    @Test func openALocalFile() {
        #expect(message(["cmd": "open", "path": "/a/b.mp4"])
                == .open(.file(URL(fileURLWithPath: "/a/b.mp4"), landing: LinkTarget())))
        #expect(message(["cmd": "open", "path": "/a.mp4", "t": 4, "seg": [1, 9]])
                == .open(.file(URL(fileURLWithPath: "/a.mp4"), landing: LinkTarget(time: 4, segments: [1...9]))))
        #expect(message(["cmd": "open", "path": "rel/a.mp4"]) == nil)
        #expect(message(["cmd": "open", "path": 5]) == nil)
        #expect(message(["cmd": "open"]) == nil)
    }

    @Test func openAStashScene() {
        #expect(message(["cmd": "open", "scene": "42", "paths": ["/mnt/a.mp4"]])
                == .open(.stashScene(id: "42", paths: ["/mnt/a.mp4"], landing: LinkTarget())))
        #expect(message(["cmd": "open", "scene": 42, "paths": ["/mnt/a.mp4"], "seg": [2, 3]])
                == .open(.stashScene(id: "42", paths: ["/mnt/a.mp4"], landing: LinkTarget(segments: [2...3]))))
        // A scene wins over a path when both are given.
        #expect(message(["cmd": "open", "scene": "1", "paths": ["/x"], "path": "/y"])
                == .open(.stashScene(id: "1", paths: ["/x"], landing: LinkTarget())))
        // Without paths (or with none) they are asked of Stash.
        #expect(message(["cmd": "open", "scene": "42"]) == .open(.stashScene(id: "42", paths: [], landing: LinkTarget())))
        #expect(message(["cmd": "open", "scene": "42", "paths": []]) == .open(.stashScene(id: "42", paths: [], landing: LinkTarget())))
        #expect(message(["cmd": "open", "scene": "42", "paths": NSNull()]) == .open(.stashScene(id: "42", paths: [], landing: LinkTarget())))
        #expect(message(["cmd": "open", "scene": "", "paths": ["/x"]]) == nil)
        #expect(message(["cmd": "open", "scene": ["42"], "paths": ["/x"]]) == nil)
        #expect(message(["cmd": "open", "scene": "42", "paths": [1, 2]]) == nil)
    }

    @Test func openRefusesBadExtras() {
        #expect(message(["cmd": "open", "path": "/a.mp4", "t": "4"]) == nil)
        #expect(message(["cmd": "open", "path": "/a.mp4", "t": -1]) == nil)
        #expect(message(["cmd": "open", "path": "/a.mp4", "seg": [9, 3]]) == nil)
        #expect(message(["cmd": "open", "path": "/a.mp4", "seg": [1]]) == nil)
        #expect(message(["cmd": "open", "path": "/a.mp4", "seg": "1-3"]) == nil)
    }

    @Test func unknownOrMissingCommand() {
        #expect(message(["cmd": "jump"]) == nil)
        #expect(message(["cmd": 1]) == nil)
        #expect(message(["t": 1]) == nil)
        #expect(message([:]) == nil)
    }

    @Test func refusalsCarryAReason() {
        func reason(_ json: [String: Any]) -> String? {
            if case let .failure(failure) = PluginMessage.parse(json) { return failure.reason }
            return nil
        }
        #expect(reason(["cmd": "jump"]) == "jump: unknown command")
        #expect(reason([:]) == "cmd must be a string")
        #expect(reason(["cmd": "seek"]) == "seek: t is missing")
        #expect(reason(["cmd": "seek", "t": "1"]) == "seek: t must be a number")
        #expect(reason(["cmd": "seek", "t": -1]) == "seek: t must not be negative")
        #expect(reason(["cmd": "loop", "a": 3, "b": 1]) == "loop: b must be above a, and a not negative")
        #expect(reason(["cmd": "open", "path": "x"]) == "open: path must be absolute")
        #expect(reason(["cmd": "open", "scene": "1", "paths": "x"]) == "open: paths must be an array of strings")
        #expect(reason(["cmd": "open", "path": "/a.mp4", "seg": [1]]) == "open: seg must be [a, b] with b above a")
        #expect(reason(["cmd": "open"]) == "open: path or scene is missing")
        #expect(reason(["cmd": "play"]) == nil)
    }

    @Test func segmentsCommand() {
        #expect(message(["cmd": "segments", "segments": [[1, 2], [3.5, 4]]]) == .segments([1...2, 3.5...4], lock: nil, advance: nil))
        #expect(message(["cmd": "segments", "segments": [[1, 2]], "lock": false, "advance": "next"])
            == .segments([1...2], lock: false, advance: .next))
        #expect(message(["cmd": "segments", "segments": [[1, 2]], "advance": "repeat"]) == .segments([1...2], lock: nil, advance: .repeating))
        #expect(message(["cmd": "segments", "segments": []]) == .segments([], lock: nil, advance: nil))
        #expect(message(["cmd": "segments"]) == .segments([], lock: nil, advance: nil))
        #expect(message(["cmd": "segments", "segments": [[1, 2], [5, 3]]]) == nil)
        #expect(message(["cmd": "segments", "segments": [[1]]]) == nil)
        #expect(message(["cmd": "segments", "segments": [[-1, 2]]]) == nil)
        #expect(message(["cmd": "segments", "segments": "1-2"]) == nil)
        #expect(message(["cmd": "segments", "segments": [[1, 2]], "advance": "loop"]) == nil)
        #expect(message(["cmd": "segments", "segments": [[1, 2]], "lock": 1]) == nil)
    }

    @Test func lockAndGoSegmentCommands() {
        #expect(message(["cmd": "lock", "on": true]) == .lock(true))
        #expect(message(["cmd": "lock", "on": false]) == .lock(false))
        #expect(message(["cmd": "lock"]) == nil)
        #expect(message(["cmd": "lock", "on": 1]) == nil)
        #expect(message(["cmd": "goSegment", "i": 2]) == .goSegment(2))
        #expect(message(["cmd": "goSegment", "i": 0]) == .goSegment(0))
        #expect(message(["cmd": "goSegment", "i": -1]) == nil)
        #expect(message(["cmd": "goSegment"]) == nil)
        #expect(message(["cmd": "goSegment", "i": "1"]) == nil)
    }

    @Test func segmentReasons() {
        func reason(_ json: [String: Any]) -> String? {
            if case let .failure(failure) = PluginMessage.parse(json) { return failure.reason }
            return nil
        }
        #expect(reason(["cmd": "segments", "segments": [[3, 1]]]) == "segments: each segment must be [a, b] with b above a")
        #expect(reason(["cmd": "segments", "segments": [[1, 2]], "advance": "x"]) == "segments: advance must be \"repeat\" or \"next\"")
        #expect(reason(["cmd": "lock"]) == "lock: on is missing")
    }

    @Test func openLandingWithSegments() {
        #expect(message(["cmd": "open", "path": "/a.mp4", "t": 4, "segments": [[1, 2], [5, 6]], "lock": false, "advance": "next"])
            == .open(.file(URL(fileURLWithPath: "/a.mp4"),
                           landing: LinkTarget(time: 4, segments: [1...2, 5...6], lock: false, advance: .next))))
        #expect(message(["cmd": "open", "scene": "9", "segments": [[1, 2]]])
            == .open(.stashScene(id: "9", paths: [], landing: LinkTarget(segments: [1...2]))))
        // segments wins over the single seg pair; seg alone stays a one-item list
        #expect(message(["cmd": "open", "path": "/a.mp4", "segments": [[1, 2]], "seg": [7, 8]])
            == .open(.file(URL(fileURLWithPath: "/a.mp4"), landing: LinkTarget(segments: [1...2]))))
        #expect(message(["cmd": "open", "path": "/a.mp4", "seg": [7, 8]])
            == .open(.file(URL(fileURLWithPath: "/a.mp4"), landing: LinkTarget(segments: [7...8]))))
        #expect(message(["cmd": "open", "path": "/a.mp4", "segments": [[2, 1]]]) == nil)
        #expect(message(["cmd": "open", "path": "/a.mp4", "advance": "x"]) == nil)
    }

    @Test func segmentEvent() {
        #expect(PluginEvent.segment(current: 1, locked: true).name == "segment")
        #expect(PluginEvent.segment(current: 1, locked: true).detail == #"{"current":1,"locked":true}"#)
        #expect(PluginEvent.segment(current: nil, locked: false).detail == #"{"current":null,"locked":false}"#)
    }

    @Test func requestIDIsANumberOrNothing() {
        #expect(PluginRequest.id(of: ["cmd": "play", "id": 7]) == 7)
        #expect(PluginRequest.id(of: ["cmd": "play", "id": 7.0]) == 7)
        #expect(PluginRequest.id(of: ["cmd": "play"]) == nil)
        #expect(PluginRequest.id(of: ["cmd": "play", "id": "7"]) == nil)
        #expect(PluginRequest.id(of: ["cmd": "play", "id": Double.nan]) == nil)
    }

    @Test func replies() {
        #expect(PluginReply.success(3) == PluginReply(id: 3, result: nil, error: nil))
        #expect(PluginReply.success(3, result: "{}") == PluginReply(id: 3, result: "{}", error: nil))
        #expect(PluginReply.failure(4, "no file") == PluginReply(id: 4, result: nil, error: "no file"))
    }

    @Test func eventsHaveANameAndJSONDetail() {
        #expect(PluginEvent.focus.name == "focus")
        #expect(PluginEvent.focus.detail == nil)
        #expect(PluginEvent.blur.name == "blur")
        #expect(PluginEvent.fileOpened(path: "/a/b.mp4", scene: nil, source: .file).name == "fileopened")
        #expect(PluginEvent.fileOpened(path: "/a/b.mp4", scene: nil, source: .file).detail == """
        {"path":"/a/b.mp4","scene":null,"source":"file"}
        """)
        #expect(PluginEvent.fileOpened(path: "/scene/42/stream", scene: "42", source: .stream).detail == """
        {"path":"/scene/42/stream","scene":"42","source":"stream"}
        """)
        #expect(PluginSource(url: URL(string: "http://h:9999/scene/42/stream")!) == .stream)
        #expect(PluginSource(url: URL(fileURLWithPath: "/a.mp4")) == .file)
        #expect(PluginEvent.error("open: path must be absolute").detail == "\"open: path must be absolute\"")
    }

    @Test func openLanding() {
        let landing = LinkTarget(time: 1, segments: [0...2])
        #expect(PluginOpen.file(URL(fileURLWithPath: "/a"), landing: landing).landing == landing)
        #expect(PluginOpen.stashScene(id: "1", paths: ["/a"], landing: landing).landing == landing)
    }
}

@Suite struct PluginStateTests {
    @Test func jsonHasEveryKeyInOrderWithNullsForNothing() {
        let state = PluginState(t: 1.5, frame: 36, fps: 24, duration: 10, playing: false, visible: true)
        #expect(state.json == """
        {"duration":10,"durationFrames":0,"fps":24,"frame":36,"loop":null,"name":null,"path":null,"playing":false,\
        "ready":false,"scene":null,"segments":null,"t":1.5,"visible":true}
        """)
    }

    @Test func pathSceneAndLoopAreWritten() {
        let state = PluginState(ready: true, path: "/Volumes/V/a b.mp4", name: "a b.mp4", scene: "42", t: 2, frame: 50,
                                fps: 25, duration: 60, durationFrames: 1500, playing: true, loop: 1...3, visible: false)
        #expect(state.json == """
        {"duration":60,"durationFrames":1500,"fps":25,"frame":50,"loop":[1,3],"name":"a b.mp4","path":"/Volumes/V/a b.mp4",\
        "playing":true,"ready":true,"scene":"42","segments":null,"t":2,"visible":false}
        """)
    }

    @Test func segmentsAreWrittenWithCurrentLockAndAdvance() {
        let segments = PluginState.Segments(list: [1...2, 3.5...4], current: 1, locked: true, advance: .next)
        let state = PluginState(t: 3.5, segments: segments)
        #expect(state.json == """
        {"duration":0,"durationFrames":0,"fps":0,"frame":0,"loop":null,"name":null,"path":null,"playing":false,\
        "ready":false,"scene":null,"segments":{"advance":"next","current":1,"list":[[1,2],[3.5,4]],"locked":true},\
        "t":3.5,"visible":true}
        """)
        let outside = PluginState(segments: PluginState.Segments(list: [1...2], current: nil, locked: false))
        #expect(outside.json?.contains(#""segments":{"advance":"repeat","current":null,"list":[[1,2]],"locked":false}"#) == true)
        #expect(state.json.flatMap(PluginState.init(json:)) == state)
        #expect(outside.json.flatMap(PluginState.init(json:)) == outside)
    }

    @Test func roundTrips() {
        let state = PluginState(ready: true, path: "/a.mp4", name: "a.mp4", scene: "7", t: 2.25, frame: 54, fps: 24,
                                duration: 100, durationFrames: 2400, playing: true, loop: 1.5...3, visible: true)
        #expect(state.json.flatMap(PluginState.init(json:)) == state)
        let bare = PluginState()
        #expect(bare.json.flatMap(PluginState.init(json:)) == bare)
    }

    @Test func aLoopThatDoesNotGoForwardIsRefused() {
        #expect(PluginState(json: """
        {"duration":1,"durationFrames":1,"fps":1,"frame":0,"loop":[3,1],"name":null,"path":null,"playing":false,\
        "ready":true,"scene":null,"t":0,"visible":true}
        """) == nil)
    }

    @Test func aNonFiniteNumberHasNoJSON() {
        #expect(PluginState(t: .nan).json == nil)
    }

    @Test func lineSeparatorsStayInThePath() {
        // U+2028 is legal inside a JSON string but not inside a JavaScript literal: the panel must not splice the
        // text into script source.
        let state = PluginState(path: "/a\u{2028}b.mp4")
        #expect(state.json?.contains("\u{2028}") == true)
        #expect(state.json.flatMap(PluginState.init(json:))?.path == "/a\u{2028}b.mp4")
    }
}
