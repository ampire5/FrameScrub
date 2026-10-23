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
                == .open(.file(URL(fileURLWithPath: "/a.mp4"), landing: LinkTarget(time: 4, segment: 1...9))))
        #expect(message(["cmd": "open", "path": "rel/a.mp4"]) == nil)
        #expect(message(["cmd": "open", "path": 5]) == nil)
        #expect(message(["cmd": "open"]) == nil)
    }

    @Test func openAStashScene() {
        #expect(message(["cmd": "open", "scene": "42", "paths": ["/mnt/a.mp4"]])
                == .open(.stashScene(id: "42", paths: ["/mnt/a.mp4"], landing: LinkTarget())))
        #expect(message(["cmd": "open", "scene": 42, "paths": ["/mnt/a.mp4"], "seg": [2, 3]])
                == .open(.stashScene(id: "42", paths: ["/mnt/a.mp4"], landing: LinkTarget(segment: 2...3))))
        // A scene wins over a path when both are given.
        #expect(message(["cmd": "open", "scene": "1", "paths": ["/x"], "path": "/y"])
                == .open(.stashScene(id: "1", paths: ["/x"], landing: LinkTarget())))
        #expect(message(["cmd": "open", "scene": "42"]) == nil)
        #expect(message(["cmd": "open", "scene": "42", "paths": []]) == nil)
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

    @Test func openLanding() {
        let landing = LinkTarget(time: 1, segment: 0...2)
        #expect(PluginOpen.file(URL(fileURLWithPath: "/a"), landing: landing).landing == landing)
        #expect(PluginOpen.stashScene(id: "1", paths: ["/a"], landing: landing).landing == landing)
    }
}

@Suite struct PluginStateTests {
    @Test func jsonHasEveryKeyInOrderWithNullsForNothing() {
        let state = PluginState(t: 1.5, frame: 36, fps: 24, duration: 10, playing: false, visible: true)
        #expect(state.json == """
        {"duration":10,"fps":24,"frame":36,"loop":null,"path":null,"playing":false,"scene":null,"t":1.5,"visible":true}
        """)
    }

    @Test func pathSceneAndLoopAreWritten() {
        let state = PluginState(path: "/Volumes/V/a b.mp4", scene: "42", t: 2, frame: 50, fps: 25, duration: 60,
                                playing: true, loop: 1...3, visible: false)
        #expect(state.json == """
        {"duration":60,"fps":25,"frame":50,"loop":[1,3],"path":"/Volumes/V/a b.mp4","playing":true,"scene":"42",\
        "t":2,"visible":false}
        """)
    }

    @Test func roundTrips() {
        let state = PluginState(path: "/a.mp4", scene: "7", t: 2.25, frame: 54, fps: 24, duration: 100,
                                playing: true, loop: 1.5...3, visible: true)
        #expect(state.json.flatMap(PluginState.init(json:)) == state)
        let bare = PluginState()
        #expect(bare.json.flatMap(PluginState.init(json:)) == bare)
    }

    @Test func aLoopThatDoesNotGoForwardIsRefused() {
        #expect(PluginState(json: """
        {"duration":1,"fps":1,"frame":0,"loop":[3,1],"path":null,"playing":false,"scene":null,"t":0,"visible":true}
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
