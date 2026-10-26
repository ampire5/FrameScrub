import Foundation

/// The settings the user edits (Preferences window, menus, export sheet). A change is applied in memory
/// and announced to the observers first; then only its keys are written to framescrub.conf, in place.
/// Keys that are not in the file and still have the value the file means without them (their default) are not added.
public final class PreferencesStore {
    public private(set) var config: Config
    private let url: URL
    private var observers: [(Config) -> Void] = []

    public init(config: Config, url: URL = Config.fileURL) {
        self.config = config
        self.url = url
    }

    public func addObserver(_ observer: @escaping (Config) -> Void) {
        observers.append(observer)
    }

    /// Throws the write error after the new value is applied: the app keeps working with it.
    public func update(_ keys: [String], _ change: (inout Config) -> Void) throws {
        let before = config
        change(&config)
        guard config != before else { return }
        for observer in observers { observer(config) }
        try persist(keys)
    }

    /// Reads framescrub.conf again (an edit made outside the app, `icon-mode`): the observers hear the new config
    /// if it differs; the file's warnings are returned for the caller to report.
    @discardableResult
    public func reload() -> [String] {
        let (fresh, warnings) = Config.load(from: url)
        if fresh != config {
            config = fresh
            for observer in observers { observer(config) }
        }
        return warnings
    }

    private func persist(_ keys: [String]) throws {
        let existing = FileManager.default.fileExists(atPath: url.path) ? try String(contentsOf: url, encoding: .utf8) : ""
        // What the file means without the key: the default.
        let (meant, _) = Config.parse(existing)
        let needed = keys.filter {
            config.text(forKey: $0) != meant.text(forKey: $0) || ConfigText.containsKey($0, in: existing)
        }
        guard !needed.isEmpty else { return }
        try config.write(keys: needed, to: url)
    }
}
