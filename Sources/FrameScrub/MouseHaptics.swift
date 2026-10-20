import Foundation
import FrameScrubCore

/// The mouse's haptic answers (mouse spec §6): a `HapticEvent` becomes its `haptic-*` pattern through
/// `LogiMouseBridge`, with `framescrub.conf` read at each call (`mouse-haptics`, `strong` → `haptic-strong-strength`).
///
/// Only the keyboard and the mouse vibrate the mouse: input runs inside `from(_:_:)` with its source, and events
/// played meanwhile for the trackpad or a menu (the seek bar counts as one) are dropped. Outside any `from` an event
/// plays: that is how asynchronous results (a frame or clip written, or not) arrive.
@MainActor final class MouseHaptics {
    typealias Source = HapticSource

    /// Set once the mouse is looked for (after the first window is up); nil plays nothing.
    var bridge: LogiMouseBridge?
    /// The settings in effect, read at each play.
    var config: () -> Config = { Config() }
    /// The input running now, nil outside `from`.
    private var source: Source?
    /// `.error` events so far, played or dropped: a toggle that met one switched nothing (see `errorCount`).
    private(set) var errorCount = 0

    init(bridge: LogiMouseBridge?) {
        self.bridge = bridge
    }

    /// Runs `body` with the events played meanwhile played only for keyboard and mouse sources. Nests: the outer
    /// source comes back afterwards.
    func from(_ source: Source, _ body: () -> Void) {
        let outer = self.source
        self.source = source
        defer { self.source = outer }
        body()
    }

    /// Plays `event`, unless the input running now is the trackpad or a menu; with `mouseOnly` (a seek's `.step`)
    /// only while mouse input runs (`HapticSource.plays`).
    func play(_ event: HapticEvent, mouseOnly: Bool = false) {
        if event == .error { errorCount += 1 }
        guard HapticSource.plays(during: source, mouseOnly: mouseOnly) else { return }
        bridge?.play(event, config: config())
    }
}
