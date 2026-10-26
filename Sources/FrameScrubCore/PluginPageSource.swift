import Foundation

/// Who asked for a plugin page: a `plugin=` line the user wrote, or a `framescrub://` link anyone could have
/// made. The panel loads `http` and `https` pages from either; a `file:` page only from the setting.
public enum PluginPageSource: Equatable, Sendable {
    case settings
    case link

    /// Whether the panel may load `url` when it comes from this source.
    public func accepts(_ url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "http", "https": true
        case "file": self == .settings
        default: false
        }
    }
}
