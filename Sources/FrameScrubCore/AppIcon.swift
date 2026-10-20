import Foundation

/// `app-icon`: the Dock icon while FrameScrub runs. A name or a path, so pictures can be added without a rebuild:
/// - a name is looked up as ~/.config/framescrub/icons/<name>.icns or <name>.png first (your own; it may also
///   replace a bundled one), then among the icons in the app (Contents/Resources/AppIcons, from
///   Resources/Icons/Alternates);
/// - a value with a `/` or starting with `~` is a path to any image file.
/// Names are case-insensitive; a name or file that is not there keeps the current icon and is reported once.
/// The PNG is shown as it is: give it the rounded square and its margins (an Icon Composer or ictool render).
public enum AppIcon {
    /// The bundle's own icon (Finder shows it too): the glass horse galloping over the gold seek bar.
    public static let bundle = "horse"
    /// The pictures in the app besides `horse` (Resources/Icons/Alternates): none bundled; your own go in
    /// ~/.config/framescrub/icons.
    public static let alternates: [String] = []

    /// Where your own pictures go: ~/.config/framescrub/icons/<name>.icns or .png.
    public static var userDirectory: URL { Config.directory.appendingPathComponent("icons", isDirectory: true) }

    /// Whether `value` names a file rather than an icon.
    public static func isPath(_ value: String) -> Bool { value.contains("/") || value.hasPrefix("~") }

    /// The value as stored: a path as written, a name lowercased; nil when it is neither (empty, or a name with
    /// characters other than letters, digits, `-`, `_` and `.`).
    public static func normalized(_ value: String) -> String? {
        if isPath(value) { return value }
        let name = value.lowercased()
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        guard !name.isEmpty, name.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        return name
    }

    /// The file for a value: the path itself, else the user's picture of that name, else `bundled(name)` (the app's
    /// AppIcons/<name>.icns). nil when there is none.
    public static func url(for value: String, userDirectory: URL = userDirectory,
                           bundled: (String) -> URL?) -> URL? {
        let files = FileManager.default
        if isPath(value) {
            let path = (value as NSString).expandingTildeInPath
            return files.fileExists(atPath: path) ? URL(fileURLWithPath: path) : nil
        }
        for ext in ["icns", "png"] {
            let url = userDirectory.appendingPathComponent("\(value).\(ext)")
            if files.fileExists(atPath: url.path) { return url }
        }
        return bundled(value)
    }
}
