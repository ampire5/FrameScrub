/// How often the player's state goes to the plugin pages. A page whose slot is on screen hears it ten times a second; a page
/// whose slot is hidden still hears it, four times a second, because a page may drive the player from the background (a roulette
/// that moves on when its piece has played). A state change (`force`) goes out at once and starts the next interval.
public struct PluginPushPacing: Sendable {
    public static let shownInterval = 0.1
    public static let hiddenInterval = 0.25

    private var lastShown = -Double.infinity
    private var lastHidden = -Double.infinity

    public init() {}

    /// Whether the pages whose slot is `shown` (or hidden) are due a push at `now` (seconds, any steady clock); records it when so.
    public mutating func due(shown: Bool, now: Double, force: Bool) -> Bool {
        let last = shown ? lastShown : lastHidden
        guard force || now - last >= (shown ? Self.shownInterval : Self.hiddenInterval) else { return false }
        if shown { lastShown = now } else { lastHidden = now }
        return true
    }
}
