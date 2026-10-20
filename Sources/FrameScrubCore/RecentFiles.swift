import Foundation

public enum RecentFiles {
    /// The start screen's recent files: in order, without duplicates and hidden ones, at most `limit`. Missing files
    /// stay (they show faint: a share that is not mounted now).
    public static func shown(_ urls: [URL], hidden: Set<String>, limit: Int = 10) -> [URL] {
        var seen = Set<URL>()
        var result: [URL] = []
        for url in urls where result.count < limit && !hidden.contains(url.path) && seen.insert(url).inserted {
            result.append(url)
        }
        return result
    }

    /// The recent files that still exist and are not hidden, in order, without duplicates, at most `limit` (the Open
    /// Recent menu).
    public static func existing(_ urls: [URL], limit: Int = 10, hidden: Set<String> = [],
                                fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> [URL] {
        var seen = Set<URL>()
        var result: [URL] = []
        for url in urls where result.count < limit && !hidden.contains(url.path) && fileExists(url)
            && seen.insert(url).inserted {
            result.append(url)
        }
        return result
    }

    /// Where a file was left, for the start screen: "0:07", "12:34", "1:02:03".
    public static func positionText(_ seconds: Double) -> String {
        let total = max(0, Int(seconds))
        let h = total / 3600, m = total / 60 % 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// The share of the file before the remembered position, for the bar on a start-screen card; nil draws no bar.
    public static func progress(position: Double?, duration: Double?) -> Double? {
        guard let position, let duration, position > 0, duration > 0 else { return nil }
        return min(1, position / duration)
    }

    /// "12:34 / 45:10", or whichever of the two is known.
    public static func timeText(position: Double?, duration: Double?) -> String? {
        let at = position.flatMap { $0 > 0 ? positionText($0) : nil }
        let length = duration.flatMap { $0 > 0 ? positionText($0) : nil }
        switch (at, length) {
        case let (at?, length?): return "\(at) / \(length)"
        case let (at?, nil): return at
        case let (nil, length?): return length
        case (nil, nil): return nil
        }
    }
}

/// Files taken off the start screen with Remove from Recent (the system's recent list cannot drop one file). Opening
/// a file again brings it back; Clear Menu empties the list. At most 200 paths, the oldest dropped.
public struct HiddenRecent {
    private let defaults: UserDefaults
    private static let key = "hiddenRecent"
    private static let limit = 200

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var paths: Set<String> { Set(list) }

    private var list: [String] { defaults.stringArray(forKey: Self.key) ?? [] }

    public mutating func hide(_ url: URL) {
        var list = list
        guard !list.contains(url.path) else { return }
        list.append(url.path)
        defaults.set(Array(list.suffix(Self.limit)), forKey: Self.key)
    }

    public mutating func reveal(_ url: URL) {
        let list = list
        guard list.contains(url.path) else { return }
        defaults.set(list.filter { $0 != url.path }, forKey: Self.key)
    }

    public mutating func clear() {
        defaults.removeObject(forKey: Self.key)
    }
}
