import Foundation
import SettingsKit
import Testing
@testable import FrameScrubCore
@testable import FrameScrubSettings

/// The settings window's store over `PreferencesStore`: values as framescrub.conf writes them, writes through the
/// preferences, and announcements of only the keys that changed, whoever changed them.
@MainActor @Suite(.serialized) struct StoreTests {
    private func conf(_ text: String? = nil) throws -> URL {
        let url = makeTemporaryDirectory().appendingPathComponent("framescrub.conf")
        if let text { try text.write(to: url, atomically: true, encoding: .utf8) }
        return url
    }

    private func defaults() -> UserDefaults {
        let name = "framescrub-settings-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    /// A value of `key` other than `current` that the conf takes and writes back the same.
    private func otherValue(_ key: String, than current: String?) -> String? {
        let candidates = ["yes", "no", "1", "2", "5", "10", "20", "50", "100", "0.5", "0.25", "keep", "default", "auto",
                          "exact", "natural", "tape", "png", "next", "fit", "frames", "fps", "take", "editing", "x", "name", "date",
                          "size", "name-desc", "date-desc", "size-desc", "3", "7", "curve", "watch", "system", "ml",
                          "lanczos", "stop", "repeat", "loop", "left-hand", "classic", "every", "scenes", "sharp",
                          "subtle-collision", "none", "sharp-collision", "strong", "frames-a-notch", "always", "never",
                          "proxy", "direct", "width:640", "http://localhost:9999", "500", "joined", "once"]
        return candidates.first { candidate in
            guard candidate != current else { return false }
            var config = Config()
            return config.set(key, candidate) && config.text(forKey: key) == candidate
        }
    }

    @Test func everyKeyRoundTrips() throws {
        let store = FrameScrubSettingsStore(preferences: PreferencesStore(config: Config(), url: try conf()),
                                            defaults: defaults())
        for key in Config.keys where !FrameScrubSettingsStore.excludedKeys.contains(key) {
            let current = store.value(forKey: key)
            #expect(current == Config().text(forKey: key), "\(key)")
            #expect(store.defaultValue(forKey: key) == Config().text(forKey: key) ?? "", "\(key)")
            guard let other = otherValue(key, than: current) else {
                Issue.record("\(key): no other value")
                continue
            }
            #expect(store.validate(other, forKey: key) == nil, "\(key)")
            try store.setValue(other, forKey: key)
            #expect(store.value(forKey: key) == other, "\(key)")
        }
    }

    @Test func validateRefusesWhatConfigRefuses() throws {
        let store = FrameScrubSettingsStore(preferences: PreferencesStore(config: Config(), url: try conf()),
                                            defaults: defaults())
        #expect(store.validate("abc", forKey: "volume") != nil)
        #expect(store.validate("50", forKey: "volume") == nil)
        #expect(store.validate("a\nb", forKey: "frame-template") != nil)
        #expect(store.validate("%{video-name}", forKey: "frame-template") == nil)
    }

    @Test func onlyChangedKeysAreAnnounced() throws {
        let preferences = PreferencesStore(config: Config(), url: try conf())
        let store = FrameScrubSettingsStore(preferences: preferences, defaults: defaults())
        var announced: [[String]] = []
        let token = NotificationCenter.default.addObserver(forName: .settingsStoreDidChange, object: store, queue: nil) {
            announced.append($0.userInfo?["keys"] as? [String] ?? [])
        }
        defer { NotificationCenter.default.removeObserver(token) }
        try preferences.update(["volume"]) { $0.volume = 30 }        // a menu or the player's 9 / 0
        try preferences.update(["volume"]) { $0.volume = 30 }        // no change: nothing
        try store.setValue("exact", forKey: "seek-mode")              // the window's own write
        #expect(announced == [["volume"], ["seek-mode"]])
    }

    @Test func reloadAnnouncesTheFileEdit() throws {
        let url = try conf("volume=50\n")
        let preferences = PreferencesStore(config: Config.parse("volume=50\n").0, url: url)
        let store = FrameScrubSettingsStore(preferences: preferences, defaults: defaults())
        var announced: [[String]] = []
        let token = NotificationCenter.default.addObserver(forName: .settingsStoreDidChange, object: store, queue: nil) {
            announced.append($0.userInfo?["keys"] as? [String] ?? [])
        }
        defer { NotificationCenter.default.removeObserver(token) }
        try "volume=30\nbogus=1\nseek-mode=sideways\n".write(to: url, atomically: true, encoding: .utf8)
        let warnings = preferences.reload()
        #expect(!warnings.isEmpty)
        #expect(announced == [["volume"]])
        #expect(store.value(forKey: "volume") == "30")
    }

    @Test func aFailedWriteThrowsWithTheValueApplied() throws {
        let blocker = makeTemporaryDirectory().appendingPathComponent("blocker")
        try "x".write(to: blocker, atomically: true, encoding: .utf8)     // a file where a directory is needed
        let preferences = PreferencesStore(config: Config(), url: blocker.appendingPathComponent("sub/framescrub.conf"))
        let store = FrameScrubSettingsStore(preferences: preferences, defaults: defaults())
        #expect(throws: (any Error).self) { try store.setValue("30", forKey: "volume") }
        #expect(store.value(forKey: "volume") == "30")
    }

    @Test func wheelFreeSpinLivesInDefaults() throws {
        let url = try conf()
        let defaults = defaults()
        let store = FrameScrubSettingsStore(preferences: PreferencesStore(config: Config(), url: url), defaults: defaults)
        let key = FrameScrubSettingsStore.wheelFreeSpinKey
        #expect(store.value(forKey: key) == "yes")                    // missing means free spin
        #expect(store.defaultValue(forKey: key) == "yes")
        #expect(store.validate("maybe", forKey: key) != nil)
        try store.setValue("no", forKey: key)
        #expect(defaults.object(forKey: FrameScrubSettingsStore.wheelFreeSpinDefaultsKey) as? Bool == false)
        #expect(store.value(forKey: key) == "no")
        #expect(!FileManager.default.fileExists(atPath: url.path))
        var announced: [[String]] = []
        let token = NotificationCenter.default.addObserver(forName: .settingsStoreDidChange, object: store, queue: nil) {
            announced.append($0.userInfo?["keys"] as? [String] ?? [])
        }
        defer { NotificationCenter.default.removeObserver(token) }
        defaults.set(true, forKey: FrameScrubSettingsStore.wheelFreeSpinDefaultsKey)   // SmartShift in the player
        store.wheelFreeSpinDidChange()
        #expect(announced == [[key]])
        #expect(store.value(forKey: key) == "yes")
    }

    @Test func removeValuesWritesOnce() throws {
        let url = try conf("volume=30\nseek-mode=exact\n")
        let preferences = PreferencesStore(config: Config.parse("volume=30\nseek-mode=exact\n").0, url: url)
        let store = FrameScrubSettingsStore(preferences: preferences, defaults: defaults())
        var announced: [[String]] = []
        let token = NotificationCenter.default.addObserver(forName: .settingsStoreDidChange, object: store, queue: nil) {
            announced.append($0.userInfo?["keys"] as? [String] ?? [])
        }
        defer { NotificationCenter.default.removeObserver(token) }
        try store.removeValues(forKeys: ["volume", "seek-mode"])
        #expect(announced.count == 1)
        #expect(Set(announced.first ?? []) == ["volume", "seek-mode"])
        #expect(store.value(forKey: "volume") == "100")
        #expect(try String(contentsOf: url, encoding: .utf8) == "volume=100\nseek-mode=keyframe\n")
    }
}

func makeTemporaryDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("framescrub-settings-tests-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
