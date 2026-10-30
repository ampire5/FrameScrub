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
                          "proxy", "direct", "width:640", "http://localhost:9999", "500", "joined", "once", "sf", "strip"]
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

    // MARK: Colour levels

    private func colourStore(_ snapshot: ColorLayerSnapshot?) throws -> (FrameScrubSettingsStore, () -> [(String, ColorLayerHit.Level)]) {
        var cleared: [(String, ColorLayerHit.Level)] = []
        let store = FrameScrubSettingsStore(preferences: PreferencesStore(config: Config(), url: try conf()),
                                            defaults: defaults(), colorLayers: { snapshot },
                                            clearColor: { cleared.append(($0, $1)) })
        return (store, { cleared })
    }

    @Test func colourLevelsAreLabelled() throws {
        let shoot = URL(fileURLWithPath: "/shoots/one", isDirectory: true)
        let shoots = URL(fileURLWithPath: "/shoots", isDirectory: true)
        let snapshot = ColorLayerSnapshot(file: ["vibrance-on": "yes"], chain: [
            ColorLayerSnapshot.Folder(url: shoot, values: ["vibrance": "0.3"]),
            ColorLayerSnapshot.Folder(url: shoots, values: ["auto-color": "yes"]),
        ])
        let (store, _) = try colourStore(snapshot)
        #expect(store.override(forKey: "vibrance-on")?.label == "This file")
        #expect(store.override(forKey: "vibrance-on")?.symbol == "doc")
        #expect(store.override(forKey: "vibrance") == SettingsOverride(
            value: "0.3", label: "This folder", symbol: "folder",
            help: "The folder of the video on screen has its own value; the setting above applies elsewhere"))
        #expect(store.override(forKey: "auto-color")?.label == "Folder shoots")
        #expect(store.override(forKey: "auto-color-strength") == nil)
        #expect(store.override(forKey: "volume") == nil)
    }

    @Test func useDefaultClearsTheLevelShown() throws {
        let shoot = URL(fileURLWithPath: "/shoots/one", isDirectory: true)
        let (store, cleared) = try colourStore(ColorLayerSnapshot(file: nil, chain: [
            ColorLayerSnapshot.Folder(url: shoot, values: ["vibrance": "0.3"])]))
        var announced: [[String]] = []
        let token = NotificationCenter.default.addObserver(forName: .settingsStoreDidChange, object: store, queue: nil) {
            announced.append($0.userInfo?["keys"] as? [String] ?? [])
        }
        defer { NotificationCenter.default.removeObserver(token) }
        store.clearFolderOverride(forKey: "vibrance")
        #expect(cleared().count == 1)
        #expect(cleared().first?.0 == "vibrance")
        #expect(cleared().first?.1 == .folder(shoot))
        #expect(announced == [["vibrance"]])
    }

    @Test func noVideoNoNote() throws {
        let (store, cleared) = try colourStore(nil)
        var posted = 0
        let token = NotificationCenter.default.addObserver(forName: .settingsStoreDidChange, object: store,
                                                           queue: nil) { _ in posted += 1 }
        defer { NotificationCenter.default.removeObserver(token) }
        #expect(store.override(forKey: "vibrance") == nil)
        store.clearFolderOverride(forKey: "vibrance")
        #expect(cleared().isEmpty)
        #expect(posted == 0)
    }

    @Test func noFiltersIsAnEmptyList() throws {
        let store = FrameScrubSettingsStore(preferences: PreferencesStore(config: Config(), url: try conf()),
                                            defaults: defaults())
        try store.setValue("", forKey: "auto-color-filters")         // the flags row with every switch off
        #expect(store.value(forKey: "auto-color-filters") == "")
        #expect(store.validate("", forKey: "auto-color-filters") == nil)
        try store.setValue("shadows", forKey: "auto-color-filters")
        #expect(store.value(forKey: "auto-color-filters") == "shadows")
    }
    @Test func thumbnailPolicyPersistsAndResetsWithoutWritingConf() throws {
        let url = try conf()
        let prefs = PreferencesStore(config: Config(), url: url)
        let domain = defaults()
        let store = FrameScrubSettingsStore(preferences: prefs, defaults: domain)
        #expect(store.value(forKey: "thumbnail-format") == "jpeg")
        #expect(store.value(forKey: "thumbnail-quality") == "80")
        #expect(store.validate("9", forKey: "thumbnail-quality") != nil)
        #expect(store.validate("101", forKey: "thumbnail-quality") != nil)
        #expect(store.validate("nan", forKey: "thumbnail-quality") != nil)
        #expect(store.validate("webp", forKey: "thumbnail-format") != nil)
        #expect(store.validate("0", forKey: "thumbnail-cache-mib") != nil)
        #expect(store.validate("127", forKey: "thumbnail-poster-size") != nil)
        #expect(store.validate("1921", forKey: "thumbnail-recent-size") != nil)
        try store.setValue("640", forKey: "thumbnail-poster-size")
        #expect(store.value(forKey: "thumbnail-poster-size") == "640")
        for value in ["29", "57", "58"] {
            try store.setValue(value, forKey: "thumbnail-quality")
            #expect(store.value(forKey: "thumbnail-quality") == value)
        }
        try store.setValue("95", forKey: "thumbnail-quality")
        try store.setValue("512", forKey: "thumbnail-cache-mib")
        let reopened = FrameScrubSettingsStore(preferences: prefs, defaults: domain)
        #expect(reopened.value(forKey: "thumbnail-quality") == "95")
        #expect(reopened.value(forKey: "thumbnail-cache-mib") == "512")
        #expect(!FileManager.default.fileExists(atPath: url.path))
        try store.removeValues(forKeys: Array(FrameScrubSettingsStore.thumbnailKeys))
        #expect(store.value(forKey: "thumbnail-quality") == "80")
        #expect(store.value(forKey: "thumbnail-cache-mib") == "256")
        #expect(store.value(forKey: "thumbnail-poster-size") == "480")
        #expect(store.value(forKey: "thumbnail-recent-size") == "1280")
    }
}

func makeTemporaryDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("framescrub-settings-tests-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url


}
