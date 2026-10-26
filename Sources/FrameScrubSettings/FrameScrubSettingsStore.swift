import Foundation
import FrameScrubCore
import SettingsKit

/// The settings window's store: a view of `PreferencesStore`, which stays the only writer of framescrub.conf (in place,
/// only the changed keys). Values are the file's text (`Config.text(forKey:)`); a write goes through
/// `PreferencesStore.update`. Every change the preferences hear — the window's own writes, a menu, the export sheet, an
/// edit of the file read back by `reload()` — is announced with `.settingsStoreDidChange` for the keys it changed only.
@MainActor
public final class FrameScrubSettingsStore: SettingsStore {
    /// `Config.keys` the window does not show: Home's open tab is state, the slots are set by View › Slots.
    public static let excludedKeys: Set<String> = ["home-tab", "slot-left", "slot-right", "slot-bottom"]
    /// The player's wheel mode (free spin or ratchet), a key of the window only: it lives in `UserDefaults`.
    public static let wheelFreeSpinKey = "wheel-free-spin"
    /// Its `UserDefaults` key; missing means free spin.
    public static let wheelFreeSpinDefaultsKey = "wheelFreeSpin"

    private let preferences: PreferencesStore
    private let defaults: UserDefaults
    private let colorLayers: () -> ColorLayerSnapshot?
    private let clearColor: (String, ColorLayerHit.Level) -> Void
    /// The config as last announced, to tell which keys a change touched.
    private var announced: Config

    /// `colorLayers` is the open video's file and folder values (nil: no video); `clearColor` drops one key of one
    /// level (the player redraws).
    public init(preferences: PreferencesStore, defaults: UserDefaults = .standard,
                colorLayers: @escaping () -> ColorLayerSnapshot? = { nil },
                clearColor: @escaping (String, ColorLayerHit.Level) -> Void = { _, _ in }) {
        self.preferences = preferences
        self.defaults = defaults
        self.colorLayers = colorLayers
        self.clearColor = clearColor
        announced = preferences.config
        preferences.addObserver { [weak self] config in
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.preferencesDidChange(config) }
            } else {
                DispatchQueue.main.async { self?.preferencesDidChange(config) }
            }
        }
    }

    /// The `Config.keys` whose file text differs between the two configs.
    public static func changedKeys(from old: Config, to new: Config) -> [String] {
        Config.keys.filter { old.text(forKey: $0) != new.text(forKey: $0) }
    }

    private func preferencesDidChange(_ config: Config) {
        let keys = Self.changedKeys(from: announced, to: config)
        announced = config
        announce(keys)
    }

    /// The player switched the wheel mode (SmartShift, the menu): the row follows.
    public func wheelFreeSpinDidChange() {
        announce([Self.wheelFreeSpinKey])
    }

    private func announce(_ keys: [String]) {
        guard !keys.isEmpty else { return }
        NotificationCenter.default.post(name: .settingsStoreDidChange, object: self, userInfo: ["keys": keys])
    }

    private var wheelFreeSpin: Bool {
        defaults.object(forKey: Self.wheelFreeSpinDefaultsKey) as? Bool ?? true
    }

    public func value(forKey key: String) -> String? {
        if key == Self.wheelFreeSpinKey { return wheelFreeSpin ? "yes" : "no" }
        return preferences.config.text(forKey: key).map { Self.shown($0, forKey: key) }
    }

    public func defaultValue(forKey key: String) -> String {
        if key == Self.wheelFreeSpinKey { return "yes" }
        return Config().text(forKey: key).map { Self.shown($0, forKey: key) } ?? ""
    }

    /// `auto-color-filters=none` is the flags row's empty list.
    private static func shown(_ text: String, forKey key: String) -> String {
        key == "auto-color-filters" && text == "none" ? "" : text
    }

    /// The window's empty list of filters as the file writes it.
    private static func written(_ value: String, forKey key: String) -> String {
        key == "auto-color-filters" && value.isEmpty ? "none" : value
    }

    /// A line break would write a second line; anything else is what `Config.set` takes.
    public func validate(_ value: String, forKey key: String) -> String? {
        if key == Self.wheelFreeSpinKey { return ["yes", "no"].contains(value) ? nil : "yes or no" }
        var config = preferences.config
        guard value.rangeOfCharacter(from: .newlines) == nil, config.set(key, Self.written(value, forKey: key)) else {
            return "Not a valid value"
        }
        return nil
    }

    /// Throws the write error after the value is applied: the app keeps working with it until it quits.
    public func setValue(_ value: String, forKey key: String) throws {
        if key == Self.wheelFreeSpinKey {
            defaults.set(value == "yes", forKey: Self.wheelFreeSpinDefaultsKey)
            announce([key])
            return
        }
        try preferences.update([key]) { _ = $0.set(key, Self.written(value, forKey: key)) }
    }

    /// The level that draws the colour key for the open video: «This file», «This folder» or «Folder <name>».
    public func override(forKey key: String) -> SettingsOverride? {
        guard let hit = colorHit(key) else { return nil }
        switch hit.level {
        case .file:
            return SettingsOverride(value: hit.value, label: "This file", symbol: "doc",
                                    help: "The video on screen has its own value; the setting above applies elsewhere")
        case .folder where hit.isNearestFolder:
            return SettingsOverride(value: hit.value, label: "This folder", symbol: "folder",
                                    help: "The folder of the video on screen has its own value; the setting above applies elsewhere")
        case .folder(let url):
            return SettingsOverride(value: hit.value, label: "Folder \(url.lastPathComponent)", symbol: "folder",
                                    help: "A folder above the video on screen has its own value; the setting above applies elsewhere")
        }
    }

    /// «Use Default»: the level shown drops its value; framescrub.conf is not written.
    public func clearFolderOverride(forKey key: String) {
        guard let hit = colorHit(key) else { return }
        clearColor(key, hit.level)
        announce([key])
    }

    private func colorHit(_ key: String) -> ColorLayerHit? {
        guard ColorLayers.keys.contains(key), let snapshot = colorLayers() else { return nil }
        return ColorLayers.nearest(key, in: snapshot, global: preferences.config)
    }

    /// Reset to Default: one write for the whole page. A key already in the file keeps its line, with the default
    /// (FrameScrub's defaults do not depend on the Mac).
    public func removeValues(forKeys keys: [String]) throws {
        let defaults = Config()
        if keys.contains(Self.wheelFreeSpinKey) { try setValue("yes", forKey: Self.wheelFreeSpinKey) }
        let conf = keys.filter { $0 != Self.wheelFreeSpinKey }
        guard !conf.isEmpty else { return }
        try preferences.update(conf) { config in
            for key in conf { if let text = defaults.text(forKey: key) { _ = config.set(key, text) } }
        }
    }
}
