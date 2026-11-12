import Foundation

/// The settings the user edits (Preferences window, menus, export sheet). A change is applied in memory
/// and announced to the observers first; then only its keys are written to framescrub.conf, in place.
/// Keys that are not in the file and still have the value the file means without them (their default) are not added.
public final class PreferencesStore {
    public private(set) var config: Config
    private let url: URL
    private var observers: [(Config) -> Void] = []
    private let writeQueue = DispatchQueue(label: "framescrub.preferences-write", qos: .utility)
    private var pendingKeys: Set<String> = []
    private var pendingError: (@MainActor (Error) -> Void)?
    private var saveTask: Task<Void, Never>?
    private var writing = false

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
        let pending = takePendingKeys().filter { !keys.contains($0) }
        let snapshot = config
        try writeQueue.sync { try Self.persist(keys + pending, config: snapshot, to: url) }
    }

    /// Apply a continuous adjustment immediately and save its final value after the input settles.
    @MainActor public func updateCoalesced(_ keys: [String], onError: @escaping @MainActor (Error) -> Void,
                                          _ change: (inout Config) -> Void) {
        let before = config
        change(&config)
        guard config != before else { return }
        pendingKeys.formUnion(keys)
        pendingError = onError
        scheduleSave()
        for observer in observers { observer(config) }
    }

    @MainActor private func scheduleSave() {
        guard !writing, !pendingKeys.isEmpty else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            guard let self else { return }
            saveTask = nil
            await flushCoalescedWrites()
        }
    }

    @MainActor public func flushCoalescedWrites() async {
        let onError = pendingError
        let keys = takePendingKeys()
        let snapshot = config
        let url = url
        writing = true
        let result: Result<Void, Error> = await withCheckedContinuation { continuation in
            writeQueue.async {
                continuation.resume(returning: Result { try Self.persist(keys, config: snapshot, to: url) })
            }
        }
        writing = false
        if case let .failure(error) = result { onError?(error) }
        scheduleSave()
    }

    /// Reads framescrub.conf again (an edit made outside the app, `icon-mode`): the observers hear the new config
    /// if it differs; the file's warnings are returned for the caller to report.
    @discardableResult
    public func reload() -> [String] {
        let keys = takePendingKeys()
        let snapshot = config
        let (fresh, warnings) = writeQueue.sync {
            do {
                try Self.persist(keys, config: snapshot, to: url)
            } catch {
                return (snapshot, ["Cannot save settings: \(error)"])
            }
            return Config.load(from: url)
        }
        if fresh != config {
            config = fresh
            for observer in observers { observer(config) }
        }
        return warnings
    }

    private func takePendingKeys() -> [String] {
        saveTask?.cancel()
        saveTask = nil
        let keys = Array(pendingKeys)
        pendingKeys.removeAll()
        pendingError = nil
        return keys
    }

    private static func persist(_ keys: [String], config: Config, to url: URL) throws {
        guard !keys.isEmpty else { return }
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
