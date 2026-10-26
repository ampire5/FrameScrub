import Foundation

/// Where the colour values a file draws with came from, for the stats line (colour memory spec §6): the file's own,
/// its folder's (or an ancestor's), or `framescrub.conf` and the built-in defaults.
public enum ColorOrigin: Sendable { case `default`, folder, file }

/// What `⇧C` / `⇧V` (and their folder forms) save: the auto colour pair or the vibrance pair.
public enum ColorSet: Sendable {
    case autoColor, vibrance

    public var keys: [String] {
        switch self {
        case .autoColor: return ["auto-color", "auto-color-strength"]
        case .vibrance: return ["vibrance-on", "vibrance"]
        }
    }
}

/// A level below `framescrub.conf` a save can write to.
public enum ColorLevel: Sendable { case file, folder }

/// The layering of per-file and per-folder colour values (colour memory spec §3, §5), on the model of Loupe's
/// `ScalingKeys.keysToClear`. Pure: the window controller asks here, then writes the stores and shows the texts.
public enum ColorLayers {
    /// The only keys a file or a folder overrides; everything else stays in `framescrub.conf`.
    public static let keys = ["auto-color", "auto-color-strength", "vibrance-on", "vibrance"]

    /// `global` with the folder chain (nearest first: the folder itself, then its ancestors) and the file's values laid
    /// over it, key by key: file → folder → nearest ancestor with the key → `global`. A stored value `Config` refuses
    /// does not draw, so the next layer shows through. `origin` is the most specific layer any of `keys` came from.
    public static func effective(global: Config, folderChain: [[String: String]], file: [String: String]?)
        -> (config: Config, origin: ColorOrigin) {
        var config = global
        var origin = ColorOrigin.default
        // Farthest ancestor first, so each nearer layer lays over the ones before it.
        let layers = folderChain.reversed().map { (values: $0, origin: ColorOrigin.folder) } + [(values: file ?? [:], origin: ColorOrigin.file)]
        for layer in layers {
            let applied = config.applyingColors(layer.values)
            config = applied.config
            if applied.accepted { origin = layer.origin }
        }
        return (config, origin)
    }

    /// After writing `set`'s effective values on `level` (`nil` is `framescrub.conf`, the default): the keys of each
    /// lower level that can go (spec §5), each list in `set.keys` order. A key goes when that level's own value is
    /// redundant, that is equal to what the level would inherit from above it after the write (or refused, so it never
    /// draws): the file's from the folder chain, then the new `global`; the folder's own (default save only) from its
    /// ancestors, then the new `global`. So the picture never changes, neither the file's nor that of a sibling file
    /// in the same folder, whose folder entry stays unless the default already says the same. A folder save lowers
    /// only the file; ancestors are never touched. `global` and the rest are as they stand before the save.
    public static func keysToClear(set: ColorSet, savedOn level: ColorLevel?, global: Config,
                                   folderChain: [[String: String]], file: [String: String]?)
        -> (file: [String], folder: [String]) {
        let before = effective(global: global, folderChain: folderChain, file: file).config
        // The write itself: the values drawn now, in the spelling of the conf.
        var written: [String: String] = [:]
        for key in set.keys { written[key] = before.text(forKey: key) }
        var newGlobal = global
        var chain = folderChain
        if level == nil {
            newGlobal = global.applying(written).config
        } else {
            if chain.isEmpty { chain = [[:]] }
            chain[0].merge(written) { _, new in new }
        }
        /// Whether `values[key]` says what the layers above it say (or nothing, being refused).
        func redundant(_ key: String, in values: [String: String], above: [[String: String]]) -> Bool {
            guard let value = values[key] else { return false }
            let applied = newGlobal.applyingColors([key: value])
            guard applied.accepted else { return true }
            let inherited = effective(global: newGlobal, folderChain: above, file: nil).config.text(forKey: key)
            return applied.config.text(forKey: key) == inherited
        }
        let clearedFile = set.keys.filter { redundant($0, in: file ?? [:], above: chain) }
        var clearedFolder: [String] = []
        if level == nil, let own = folderChain.first {
            clearedFolder = set.keys.filter { redundant($0, in: own, above: Array(folderChain.dropFirst())) }
        }
        return (clearedFile, clearedFolder)
    }
}

/// The colour values below `framescrub.conf` for the open video: its own, and its folder's and each ancestor's
/// (nearest first), as the settings window asks for them.
public struct ColorLayerSnapshot: Equatable, Sendable {
    /// One folder of the chain and the values it records itself.
    public struct Folder: Equatable, Sendable {
        public var url: URL
        public var values: [String: String]
        public init(url: URL, values: [String: String]) {
            self.url = url
            self.values = values
        }
    }

    public var file: [String: String]?
    public var chain: [Folder]

    public init(file: [String: String]?, chain: [Folder]) {
        self.file = file
        self.chain = chain
    }
}

/// The level whose value of a key draws for the open video.
public struct ColorLayerHit: Equatable, Sendable {
    public enum Level: Equatable, Sendable { case file, folder(URL) }
    public let level: Level
    /// As the file writes it.
    public let value: String
    /// The level is the video's own folder (not an ancestor).
    public let isNearestFolder: Bool

    public init(level: Level, value: String, isNearestFolder: Bool) {
        self.level = level
        self.value = value
        self.isNearestFolder = isNearestFolder
    }
}

extension ColorLayers {
    /// The most specific level that sets `key` and draws, as `effective` lays them: the file, then the folder, then
    /// the nearest ancestor with the key. A value `Config` refuses does not draw, so the next level shows. nil for a key
    /// no file or folder overrides (`keys`) and when no level sets it.
    public static func nearest(_ key: String, in snapshot: ColorLayerSnapshot, global: Config) -> ColorLayerHit? {
        guard keys.contains(key) else { return nil }
        func draws(_ values: [String: String]?) -> String? {
            guard let value = values?[key], global.applyingColors([key: value]).accepted else { return nil }
            return value
        }
        if let value = draws(snapshot.file) { return ColorLayerHit(level: .file, value: value, isNearestFolder: false) }
        for (index, folder) in snapshot.chain.enumerated() {
            if let value = draws(folder.values) {
                return ColorLayerHit(level: .folder(folder.url), value: value, isNearestFolder: index == 0)
            }
        }
        return nil
    }
}
