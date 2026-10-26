import Foundation
import Testing
@testable import FrameScrubCore

@Suite struct FolderWaitTests {
    @Test func runsAtOnceWithNoReadRunning() {
        var wait = FolderWait()
        var ran = 0
        wait.take(reading: false) { ran += 1 }?()
        #expect(ran == 1)
        wait.readEnded()?()
        #expect(ran == 1)
    }

    @Test func waitsForTheReadWithoutBlocking() {
        var wait = FolderWait()
        var ran: [String] = []
        #expect(wait.take(reading: true) { ran.append("next") } == nil)
        #expect(ran.isEmpty)   // the caller goes on: nothing waits on the read
        wait.readEnded()?()
        #expect(ran == ["next"])
        #expect(wait.readEnded() == nil)   // once
    }

    @Test func aLaterCommandReplacesOneStillWaiting() {
        var wait = FolderWait()
        var ran: [String] = []
        #expect(wait.take(reading: true) { ran.append("previous") } == nil)
        #expect(wait.take(reading: true) { ran.append("next") } == nil)
        wait.readEnded()?()
        #expect(ran == ["next"])
    }

    @Test func cancelDropsTheWaitingCommand() {
        var wait = FolderWait()
        var ran = 0
        #expect(wait.take(reading: true) { ran += 1 } == nil)
        wait.cancel()
        #expect(wait.readEnded() == nil && ran == 0)
    }

    /// › with the folder read (2026-10-26 crash): the step opens a file, and the open cancels the wait. Run inside the
    /// wait's own mutating call, the two accesses to the window's `folderWait` overlapped and Swift stopped the app.
    @Test func theActionRunsAfterTheWaitIsLeft() {
        final class Window { var wait = FolderWait(); var opened = 0 }
        let window = Window()
        window.wait.take(reading: false) {
            window.wait.cancel()   // what openFile does
            window.opened += 1
        }?()
        #expect(window.opened == 1)
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
