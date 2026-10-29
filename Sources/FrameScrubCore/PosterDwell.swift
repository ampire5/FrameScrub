import Foundation

/// Which rows of the playlist strip get a poster made (spec 2026-10-27-playlist-strip, «Posters on dwell»): only those
/// that have stayed in the visible window for `delay`, so a flick across the list makes nothing. A row that leaves the
/// window starts its wait again when it comes back; a file is given once until `reset()`; at most `cap` at a time.
/// Pure: the owner gives the rows in view and the time, and keeps one one-shot timer for `nextDeadline`.
public struct PosterDwell: Sendable {
    public static let delay = 0.3
    public static let cap = 24
    /// Rounding, and a timer that wakes a hair early, still count as on time.
    private static let slack = 1e-6

    /// When each file in view came into it.
    private var seen: [URL: Double] = [:]
    private var given: Set<URL> = []

    public init() {}

    /// The rows in view now, in window order (nil: nothing to make); the files due, at most `cap`.
    public mutating func visible(_ urls: [URL?], now: Double) -> [URL] {
        let inView = urls.compactMap { $0 }
        let current = Set(inView)
        seen = seen.filter { current.contains($0.key) }
        for url in inView where seen[url] == nil { seen[url] = now }
        var due: [URL] = []
        for url in inView where due.count < Self.cap && !given.contains(url) && now - seen[url]! >= Self.delay - Self.slack {
            due.append(url)
            given.insert(url)
        }
        return due
    }

    /// When the next row in view comes due; nil when none waits.
    public var nextDeadline: Double? {
        seen.filter { !given.contains($0.key) }.values.min().map { $0 + Self.delay }
    }

    /// The list changed or the slot hid: every file may be asked again.
    public mutating func reset() {
        seen = [:]
        given = []
    }
}
