import Foundation

/// A second launch passes its file to the running FrameScrub through a distributed notification, which every running
/// FrameScrub hears, whichever build it is. Each note names the bundle that sent it, and a running copy takes only
/// notes from its own bundle: a dev build beside the installed app no longer opens what the installed app's second
/// launch was given (seen 2026-10-27). Notes without a bundle (older builds) are taken, as before.
public enum HandOver {
    public static let bundleKey = "bundle"

    public static func userInfo(path: String?, link: URL?, bundle: String) -> [String: String] {
        var info = [bundleKey: standardized(bundle)]
        if let path { info["path"] = path }
        if let link { info["link"] = link.absoluteString }
        return info
    }

    public static func isForUs(_ userInfo: [AnyHashable: Any]?, ownBundle: String) -> Bool {
        guard let sender = userInfo?[bundleKey] as? String else { return true }
        return standardized(sender) == standardized(ownBundle)
    }

    /// Which running copies count as this app for single-instance: one bundle path is one app, so two builds sharing
    /// a bundle identifier do not hand files to each other (the other would refuse them). Without a bundle, the
    /// executable's path.
    public static func instanceKey(bundlePath: String?, executablePath: String?) -> String? {
        if let bundlePath { return standardized(bundlePath) }
        return executablePath
    }

    private static func standardized(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }
}
