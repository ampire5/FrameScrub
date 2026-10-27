/// The playlist strip's two rows (spec 2026-10-27-playlist-strip): `playing`, the open video, and `browsed`, the row
/// at the strip's centre. Scrolling moves `browsed` only; opening a row sets both. Left alone, `browsed` goes back to
/// `playing` `returnDelay` seconds after the last browse or activity (0: never): the owner keeps one one-shot timer
/// for `returnDeadline` and calls `fire(now:)` when it wakes. Pure: the owner gives the times.
public struct PlaylistStripState: Equatable, Sendable {
    public private(set) var playing: Int?
    public private(set) var browsed: Int?
    /// When the strip goes back to `playing`; nil: nothing armed.
    public private(set) var returnDeadline: Double?
    private let returnDelay: Double
    private var count = 0
    /// A gesture, the pointer or typing holds the strip where it is: no return is armed meanwhile.
    private var holding = false

    public init(returnDelay: Double) {
        self.returnDelay = returnDelay
    }

    /// The rows changed (a filter, the order, a file added) or the playing video did: `map` takes old row indices to
    /// new ones (`FilmstripItems.indexMap`). At rest on the playing row, the strip follows the playing video; a browsed
    /// row stays on its file, or falls back to the playing row (else the first) when it left the list.
    public mutating func rowsChanged(count: Int, playing: Int?, map: [Int: Int]) {
        self.count = max(0, count)
        guard self.count > 0 else {
            self.playing = nil
            browsed = nil
            returnDeadline = nil
            return
        }
        let playing = playing.flatMap { (0..<self.count).contains($0) ? $0 : nil }
        let follows = browsed == nil || (browsed == self.playing && !holding)
        let fallback = playing ?? 0
        browsed = follows ? fallback : browsed.flatMap { map[$0] }.flatMap { $0 < self.count ? $0 : nil } ?? fallback
        self.playing = playing
        if playing == nil || browsed == playing { returnDeadline = nil }
    }

    /// A row was opened (by the strip, the keys or autoadvance).
    public mutating func opened(_ row: Int) {
        guard (0..<count).contains(row) else { return }
        playing = row
        browsed = row
        holding = false
        returnDeadline = nil
    }

    /// The strip's centre reached `row` (a scroll, a drag, a key in the filter).
    public mutating func browse(to row: Int, now: Double, inGesture: Bool) {
        guard count > 0 else { return }
        browsed = min(max(row, 0), count - 1)
        holding = inGesture
        arm(now: now)
    }

    /// The user is still at the strip (`inGesture`: a gesture goes on, the pointer is over it, the filter is typed in)
    /// or has just left it.
    public mutating func activity(now: Double, inGesture: Bool) {
        guard count > 0 else { return }
        holding = inGesture
        arm(now: now)
    }

    /// The return timer woke: true when `browsed` went back to `playing`.
    public mutating func fire(now: Double) -> Bool {
        guard let deadline = returnDeadline, now >= deadline, let playing else { return false }
        browsed = playing
        returnDeadline = nil
        return true
    }

    /// The slot hid or the window is not visible: nothing stays armed.
    public mutating func cancel() {
        returnDeadline = nil
    }

    private mutating func arm(now: Double) {
        guard !holding, returnDelay > 0, let playing, browsed != playing else {
            returnDeadline = nil
            return
        }
        returnDeadline = now + returnDelay
    }
}
