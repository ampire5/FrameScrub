import Foundation
import Testing
@testable import FrameScrubCore

@Suite struct FolderWaitTests {
    @Test func runsAtOnceWithNoReadRunning() {
        var wait = FolderWait()
        var ran = 0
        wait.run(reading: false) { ran += 1 }
        #expect(ran == 1)
        wait.readEnded()?()
        #expect(ran == 1)
    }

    @Test func waitsForTheReadWithoutBlocking() {
        var wait = FolderWait()
        var ran: [String] = []
        wait.run(reading: true) { ran.append("next") }
        #expect(ran.isEmpty)   // the caller goes on: nothing waits on the read
        wait.readEnded()?()
        #expect(ran == ["next"])
        #expect(wait.readEnded() == nil)   // once
    }

    @Test func aLaterCommandReplacesOneStillWaiting() {
        var wait = FolderWait()
        var ran: [String] = []
        wait.run(reading: true) { ran.append("previous") }
        wait.run(reading: true) { ran.append("next") }
        wait.readEnded()?()
        #expect(ran == ["next"])
    }

    @Test func cancelDropsTheWaitingCommand() {
        var wait = FolderWait()
        var ran = 0
        wait.run(reading: true) { ran += 1 }
        wait.cancel()
        #expect(wait.readEnded() == nil && ran == 0)
    }

    @Test func theFileBeingOpenedAnchorsThePlaylist() {
        let open = URL(fileURLWithPath: "/v/a.mp4"), opening = URL(fileURLWithPath: "/v/b.mp4")
        let failed = URL(fileURLWithPath: "/v/c.mp4")
        #expect(FolderWait.anchor(open: open, opening: nil, failed: nil) == open)
        #expect(FolderWait.anchor(open: nil, opening: opening, failed: failed) == opening)   // › during an open
        #expect(FolderWait.anchor(open: nil, opening: nil, failed: failed) == failed)
        #expect(FolderWait.anchor(open: nil, opening: nil, failed: nil) == nil)
    }
}
