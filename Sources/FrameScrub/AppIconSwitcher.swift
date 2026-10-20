import AppKit
import FrameScrubCore

/// Puts `app-icon` in the Dock: a picture from ~/.config/framescrub/icons, a bundled alternate (`AppIcons/<name>.icns`,
/// compiled by make-app.sh from Resources/Icons/Alternates) or a file path; `horse` with no file of that name is the
/// bundle's icon. Only the running app's Dock icon changes; Finder keeps the bundle's. A missing picture (`swift run`
/// has no bundle) keeps the current icon and says so once.
final class AppIconSwitcher {
    /// The value last applied; nil until the first `apply` (the bundle's icon is showing).
    private var applied: String?

    func apply(_ choice: String) {
        guard choice != applied else { return }
        let previous = applied
        applied = choice
        let url = AppIcon.url(for: choice) {
            Bundle.main.url(forResource: $0, withExtension: "icns", subdirectory: "AppIcons")
        }
        if let url, let image = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = image
            return
        }
        guard choice == AppIcon.bundle else {
            FileHandle.standardError.write(Data("framescrub: app-icon=\(choice): no such picture (looked in \(AppIcon.userDirectory.path) and the app bundle)\n".utf8))
            return
        }
        // At launch the bundle's icon is already showing. Setting nil does not bring it back on macOS 26 (the Dock
        // keeps the alternate), so the bundle's icon is set explicitly, at 512 pt: NSWorkspace's image is 32 pt,
        // which the Dock and Cmd-Tab got as a pixelated bitmap.
        if previous != nil {
            let icon = NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
            icon.size = NSSize(width: 512, height: 512)
            NSApp.applicationIconImage = icon
        }
    }
}
