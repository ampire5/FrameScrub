import Foundation
import os

/// The decisions of the colour commands for the open file (colour memory spec §5): what to write where, the OSD text
/// and the haptic. `c`, `v` and the strength step write the file's own values; the folder saves write the folder; a
/// default save hands the app the lines for `framescrub.conf` and, once they are written, clears what became redundant
/// below. Files go to `ResumeStore`, folders to `FolderColors`; the window controller runs the outcomes and shows them.
/// Main thread only.
public final class ColorMemory {
    /// What a command decided: the text for the OSD, `framescrub.conf` lines the app still has to write (a default
    /// save), and the haptic to play (nil: none).
    public struct Outcome: Equatable {
        public var osd: String
        public var globalWrites: [String: String]
        public var haptic: HapticEvent?

        public init(osd: String, globalWrites: [String: String] = [:], haptic: HapticEvent? = nil) {
            self.osd = osd
            self.globalWrites = globalWrites
            self.haptic = haptic
        }
    }

    private static let logger = Logger(subsystem: "local.framescrub", category: "ColorMemory")
    private static let loggedLock = NSLock()
    private static var logged: Set<String> = []

    private let folders: FolderColors
    private let files: ResumeStore?
    private var url: URL?
    private var size: Int64?
    /// The open file's own values, kept here so an edit holds until the file is closed even when its record can't be written.
    private var fileValues: [String: String]?

    public init(folders: FolderColors, files: ResumeStore?) {
        self.folders = folders
        self.files = files
    }

    /// The open file (nil: none); `size` as `ResumeStore` takes it.
    public func open(_ url: URL?, size: Int64?) {
        self.url = url
        self.size = size
        fileValues = url.flatMap { files?.color(for: $0, size: size) }
        if let url, files != nil, ResumeStore.key(for: url, size: size) == nil, Self.logOnce("unsaved:\(url.path)") {
            Self.logger.error("no size for \(url.lastPathComponent, privacy: .public): its colour edits last until it is closed")
        }
    }

    /// `global` with the open file's and its folders' values laid over it, and where they came from.
    public func effective(global: Config) -> (config: Config, origin: ColorOrigin) {
        guard let folder else { return (global, .default) }
        let chain = folders.chain(for: folder)
        for values in chain + [fileValues ?? [:]] {
            for entry in global.applying(values).rejected where Self.logOnce(entry) {
                Self.logger.error("stored colour value '\(entry, privacy: .public)' is refused and skipped")
            }
        }
        return ColorLayers.effective(global: global, folderChain: chain, file: fileValues)
    }

    /// `c` / `v`: the opposite of the effective on / off, pinned on the file even when it equals the inherited one.
    public func toggle(_ set: ColorSet, global: Config) -> Outcome {
        guard url != nil else { return Self.noVideo }
        let config = effective(global: global).config
        let (key, label, now) = set == .autoColor ? ("auto-color", "Auto colour", config.autoColor)
                                                  : ("vibrance-on", "Vibrance", config.vibranceOn)
        writeFile([key: now ? "no" : "yes"])
        return Outcome(osd: "\(label): \(now ? "off" : "on") · file", haptic: .toggle)
    }

    /// The panel and wheel: the effective strength one step on (0.05 grid, 0…1), written to the file. Against an end
    /// the value is unchanged and nothing is written.
    public func addStrength(_ delta: Double, global: Config) -> Outcome {
        guard url != nil else { return Self.noVideo }
        let config = effective(global: global).config
        let current = config.autoColorStrength
        let (value, event) = AdjustStep.apply(current, by: delta, step: 0.05, range: 0...1, detents: [0.25, 0.5, 0.75])
        if value != current { writeFile(["auto-color-strength": formatNumber(value)]) }
        return Outcome(osd: "Auto colour strength \(String(format: "%.2f", value)) · file" + (config.autoColor ? "" : " (off)"),
                       haptic: event)
    }

    /// `⇧C` / `⇧V` (`level` nil: the default, `globalWrites` for the app to put into `framescrub.conf`) and `⌥C` /
    /// `⌥V` (`.folder`): the effective values of `set` on that level, so the picture stays as it is. A folder save also
    /// drops the file's values it makes redundant at once; a default save does it in `finishDefaultSave`, after the
    /// app has written the lines. `.file` is not a save level (the keys that write the file are `toggle` and
    /// `addStrength`) and does nothing.
    public func save(_ set: ColorSet, on level: ColorLevel?, global: Config) -> Outcome {
        guard let folder else { return Self.noVideo }
        let label = set == .autoColor ? "Auto colour" : "Vibrance"
        let config = effective(global: global).config
        var written: [String: String] = [:]
        for key in set.keys { written[key] = config.text(forKey: key) }
        switch level {
        case nil:
            return Outcome(osd: "\(label) saved as default", globalWrites: written)
        case .folder?:
            let cleared = ColorLayers.keysToClear(set: set, savedOn: .folder, global: global,
                                                  folderChain: folders.chain(for: folder), file: fileValues)
            folders.set(written, for: folder)
            clearFile(cleared.file)
            return Outcome(osd: "\(label) saved for the folder")
        case .file?:
            return Outcome(osd: "")
        }
    }

    /// After the app wrote a default save's `globalWrites` into `framescrub.conf`: removes the file's and the folder's
    /// values of `set` that the new default makes redundant. `global` is the config as it stood before the save.
    public func finishDefaultSave(_ set: ColorSet, global: Config) {
        guard let folder else { return }
        let cleared = ColorLayers.keysToClear(set: set, savedOn: nil, global: global,
                                              folderChain: folders.chain(for: folder), file: fileValues)
        clearFile(cleared.file)
        if !cleared.folder.isEmpty { folders.clear(cleared.folder, for: folder) }
    }

    /// Menu: drops all the colour values of the file or of its folder.
    public func reset(_ level: ColorLevel) -> Outcome {
        guard let folder else { return Self.noVideo }
        switch level {
        case .file:
            clearFile(ColorLayers.keys)
            return Outcome(osd: "File colour reset")
        case .folder:
            folders.clear(Array(folders.own(for: folder).keys), for: folder)
            return Outcome(osd: "Folder colour reset")
        }
    }

    /// Whether the file / its folder has values of its own (the Reset items are enabled by it).
    public func hasOwn(_ level: ColorLevel) -> Bool {
        guard let folder else { return false }
        switch level {
        case .file: return !(fileValues ?? [:]).isEmpty
        case .folder: return !folders.own(for: folder).isEmpty
        }
    }

    /// The open file's values and its folder chain (nearest first, each folder's own values); nil without a file.
    public func snapshot() -> ColorLayerSnapshot? {
        guard let folder else { return nil }
        let chain = zip(FolderColors.ancestors(of: folder), folders.chain(for: folder)).map { path, values in
            ColorLayerSnapshot.Folder(url: URL(fileURLWithPath: path, isDirectory: true), values: values)
        }
        return ColorLayerSnapshot(file: fileValues, chain: chain)
    }

    /// The settings window's «Use Default»: `level` drops its value of `key`; the levels above it show again.
    public func clear(_ key: String, on level: ColorLayerHit.Level) {
        switch level {
        case .file: clearFile([key])
        case .folder(let url): folders.clear([key], for: url)
        }
    }

    // MARK: Private

    private static let noVideo = Outcome(osd: "No video open", haptic: .error)

    /// The folder of the open file.
    private var folder: URL? { url?.deletingLastPathComponent() }

    private func writeFile(_ values: [String: String]) {
        var all = fileValues ?? [:]
        all.merge(values) { _, new in new }
        store(all)
    }

    private func clearFile(_ keys: [String]) {
        guard var all = fileValues, keys.contains(where: { all[$0] != nil }) else { return }
        for key in keys { all[key] = nil }
        store(all)
    }

    private func store(_ values: [String: String]) {
        fileValues = values.isEmpty ? nil : values
        guard let url else { return }
        files?.setColor(fileValues, for: url, size: size)
    }

    /// Whether `message` is new: each rejected value and unsaved file is logged once per process (spec §8).
    private static func logOnce(_ message: String) -> Bool {
        loggedLock.lock()
        defer { loggedLock.unlock() }
        return logged.insert(message).inserted
    }

    /// The `key=value` texts logged as refused so far (for tests).
    static var loggedRejections: Set<String> {
        loggedLock.lock()
        defer { loggedLock.unlock() }
        return logged
    }
}
