import AppKit
import FrameScrubCore
import SettingsKit

/// Puts `app-icon` in the Dock: a picture from ~/.config/framescrub/icons, a bundled alternate (`AppIcons/<name>.icns`,
/// compiled by make-app.sh from Resources/Icons/Alternates) or a file path; `horse` with no file of that name is the
/// bundle's icon. Only the running app's Dock icon changes; Finder keeps the bundle's. A missing picture (`swift run`
/// has no bundle) keeps the current icon and says so once.
@MainActor
final class AppIconSwitcher {
    /// The value last applied; nil until the first `apply` (the bundle's icon is showing).
    private var applied: String?

    /// View › App Icon… (⌃⌥⌘I): the picker window of `choices`; a click is written to framescrub.conf and applied
    /// through the store's observers like any other preference.
    private var picker: IconPickerWindowController?

    @MainActor func showPicker(preferences: PreferencesStore) {
        if picker == nil {
            picker = IconPickerWindowController(
                choices: { Self.choices(current: preferences.config.appIcon) },
                current: { preferences.config.appIcon },
                onPick: { word in
                    do { try preferences.update(["app-icon"]) { $0.appIcon = word } }
                    catch { FileHandle.standardError.write(Data("framescrub: app-icon not saved: \(error.localizedDescription)\n".utf8)) }
                })
        }
        picker?.show()
    }

    /// `horse` and bundled alternates (Built-in), loose user pictures (Yours), one section per folder pack, and
    /// the current external path (Other), each with its file; the picker makes
    /// their thumbnails off the main thread.
    nonisolated static func choices(current: String) -> [IconChoice] {
        let builtIn = [AppIcon.bundle] + AppIcon.alternates.filter { bundled($0) != nil }
        var choices = builtIn.map { word in
            let url = AppIcon.url(for: word, bundled: bundled)
                ?? (word == AppIcon.bundle ? Bundle.main.url(forResource: "AppIcon", withExtension: "icns") : nil)
            return IconChoice(word: word, file: url, section: builtIn.contains(word) ? "Built-in" : "Yours")
        }
        for icon in AppIcon.userIcons() where !builtIn.contains(icon.value) {
            choices.append(IconChoice(word: icon.value, file: icon.file,
                                      section: icon.pack?.lastPathComponent ?? "Yours", pack: icon.pack?.path))
        }
        if AppIcon.isPath(current), !choices.contains(where: { $0.word == current }) {
            choices.append(IconChoice(word: current, file: AppIcon.url(for: current, bundled: bundled), section: "Other"))
        }
        return choices
    }

    nonisolated private static func bundled(_ name: String) -> URL? {
        Bundle.main.url(forResource: name, withExtension: "icns", subdirectory: "AppIcons")
    }

    func apply(_ choice: String) {
        guard choice != applied else { return }
        let previous = applied
        applied = choice
        let url = AppIcon.url(for: choice, bundled: Self.bundled)
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
