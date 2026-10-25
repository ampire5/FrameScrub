import Foundation
import Testing
@testable import FrameScrubCore

@Suite struct PreferencesStoreTests {
    private func url(containing text: String? = nil) throws -> URL {
        let url = makeTemporaryDirectory().appendingPathComponent("framescrub.conf")
        if let text { try text.write(to: url, atomically: true, encoding: .utf8) }
        return url
    }

    @Test func changesTheValueInPlaceAndKeepsTheUsersFile() throws {
        let file = try url(containing: "# mine\nvolume=50  # quiet\nunknown=1\n")
        let store = PreferencesStore(config: Config(), url: file)
        try store.update(["volume"]) { $0.volume = 70 }
        #expect(try String(contentsOf: file, encoding: .utf8) == "# mine\nvolume=70 # quiet\nunknown=1\n")
        #expect(store.config.volume == 70)
    }

    @Test func aDefaultValueThatIsNotInTheFileIsNotAppended() throws {
        let file = try url(containing: "volume=50\n")
        let store = PreferencesStore(config: Config(), url: file)
        try store.update(["seek-mode"]) { $0.seekMode = .exact }     // non-default: appended
        try store.update(["seek-mode"]) { $0.seekMode = .keyframe }  // back to default, key is in the file: rewritten
        try store.update(["preview"]) { $0.preview = false }
        try store.update(["preview"]) { $0.preview = true }
        #expect(try String(contentsOf: file, encoding: .utf8) == "volume=50\nseek-mode=keyframe\npreview=yes\n")
    }

    @Test func aSlotEqualToTheDefaultIsWrittenWhenTheFileMeansAnotherOne() throws {
        // With plugin-url and no slot-* keys the bottom slot migrates to the playlist; clearing it back to the plain
        // default must be written, or the playlist returns on the next launch.
        let file = try url(containing: "plugin-url=http://host:8000/page/\n")
        let (config, _) = Config.parse(try String(contentsOf: file, encoding: .utf8))
        let store = PreferencesStore(config: config, url: file)
        try store.update([SlotEdge.bottom.key]) { $0.slots[.bottom] = .default(for: .bottom) }
        let (reread, _) = Config.parse(try String(contentsOf: file, encoding: .utf8))
        #expect(reread.slots[.bottom] == .default(for: .bottom))
    }

    @Test func aDefaultChangeOnAMissingFileCreatesNothing() throws {
        let file = try url()
        let store = PreferencesStore(config: Config(), url: file)
        try store.update(["sharpen"]) { $0.sharpen = 0.5 }
        try store.update(["sharpen"]) { $0.sharpen = 0.3 }
        #expect(try String(contentsOf: file, encoding: .utf8) == ConfigText.header + "\nsharpen=0.3\n")
        let empty = try url()
        let other = PreferencesStore(config: Config(), url: empty)
        try other.update(["volume"]) { $0.volume = 100 }             // unchanged: no write at all
        #expect(!FileManager.default.fileExists(atPath: empty.path))
    }

    @Test func observersHearAboutEveryChangeButNotAboutNoOps() throws {
        let store = PreferencesStore(config: Config(), url: try url())
        var seen: [Double] = []
        store.addObserver { seen.append($0.volume) }
        try store.update(["volume"]) { $0.volume = 70 }
        try store.update(["volume"]) { $0.volume = 70 }
        try store.update(["volume"]) { $0.volume = 20 }
        #expect(seen == [70, 20])
    }

    @Test func aFailedWriteStillAppliesTheValueAndNotifies() throws {
        let blocker = makeTemporaryDirectory().appendingPathComponent("blocker")
        try "x".write(to: blocker, atomically: true, encoding: .utf8)        // a file where a directory is needed
        let store = PreferencesStore(config: Config(), url: blocker.appendingPathComponent("sub/framescrub.conf"))
        var notified = false
        store.addObserver { _ in notified = true }
        #expect(throws: (any Error).self) { try store.update(["volume"]) { $0.volume = 70 } }
        #expect(store.config.volume == 70)
        #expect(notified)
    }

    @Test func containsKeyIgnoresCommentsAndCase() {
        #expect(ConfigText.containsKey("volume", in: "  Volume = 5\n"))
        #expect(!ConfigText.containsKey("volume", in: "# volume=5\n"))
    }
}
