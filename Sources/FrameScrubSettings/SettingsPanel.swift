import AppKit
import FrameScrubCore
import SettingsKit

/// What the pages need from the app beyond the store. The settings code never reaches the app's objects itself: the
/// app passes everything in.
public struct SettingsPanelContext {
    /// The live bindings and the user's binding files, for the Key Bindings tables and the gesture table.
    public var inputPreferences: InputPreferences
    /// The `app-icon` row's pictures: the built-in icons and the pictures in ~/.config/framescrub/icons. Asked for
    /// when the row's grid opens.
    public var iconChoices: @MainActor () -> [IconChoice]
    /// One `app-icon` value's picture, for the row (which shows only the current one); nil: looked up in
    /// `iconChoices`.
    public var iconChoice: (@MainActor (String) -> IconChoice?)?
    /// The Latin character a key code types, with or without Shift, on the ASCII-capable layout: the key recorder
    /// binds a letter by it.
    public var translateKey: (UInt16, Bool) -> String?
    /// The menus' shortcuts for the Key Bindings page, read-only.
    public var menuRows: @MainActor () -> [(input: String, title: String)]

    public init(inputPreferences: InputPreferences, iconChoices: @escaping @MainActor () -> [IconChoice] = { [] },
                iconChoice: (@MainActor (String) -> IconChoice?)? = nil,
                translateKey: @escaping (UInt16, Bool) -> String? = { _, _ in nil },
                menuRows: @escaping @MainActor () -> [(input: String, title: String)] = { [] }) {
        self.inputPreferences = inputPreferences
        self.iconChoices = iconChoices
        self.iconChoice = iconChoice
        self.translateKey = translateKey
        self.menuRows = menuRows
    }
}

/// The settings window (⌘,): one per app, made on the first `show`, never at launch.
@MainActor public enum SettingsPanel {
    /// The context of the last `show`: what the pages' closures (icon choices, the tables) ask.
    static var context: SettingsPanelContext?
    /// The store of the first `show`: what the Stash check reads.
    static var store: FrameScrubSettingsStore?
    /// The Key Bindings tables' source, made on the first `show` over the context's bindings.
    static var bindingSource: InputBindingSource?

    /// Frame autosave name of the window.
    static let autosaveName = "FrameScrubSettings"
    /// `UserDefaults` key of the open page.
    static let lastPageDefaultsKey = "settingsLastPage"

    private static var controller: SettingsWindowController?
    private static var model: SettingsModel?
    private static var terminateObserver: NSObjectProtocol?

    /// The pages in the sidebar's order.
    public static func pages() -> [SettingsPage] {
        [general, speed, home, scrolling, mouse, keyBindings, saving, display, colour, performance, stash, advanced]
    }

    /// Brings the window to the front, making it on the first call (on the page it was last on). Later calls keep
    /// the first store and context.
    /// - Parameter page: a page id to open, or nil for the page the window is on.
    public static func show(store: FrameScrubSettingsStore, context: SettingsPanelContext, page: String? = nil) {
        if controller == nil {
            self.store = store
            self.context = context
            bindingSource = InputBindingSource(preferences: context.inputPreferences, translateKey: context.translateKey,
                                               menuRows: context.menuRows)
            gestureModel = GestureTableModel(preferences: context.inputPreferences)
            let model = SettingsModel(store: store)
            self.model = model
            controller = SettingsWindowController(pages: pages(), model: model, autosaveName: autosaveName,
                                                  lastPageDefaultsKey: lastPageDefaultsKey, style: .glass)
            // No tab bar, + or Window menu tab items.
            controller?.window?.tabbingMode = .disallowed
            // ⌘Q while a field is being edited: its text is written first, as on ⌘W.
            terminateObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.willTerminateNotification, object: nil, queue: nil
            ) { _ in
                MainActor.assumeIsolated { controller?.endEditing() }
            }
        }
        model?.refreshFolderOverrides()
        controller?.show(page: page)
    }

    /// The colour notes ask the store again: the app calls it when a video opened or closed, or a file's or folder's
    /// colour changed. Nothing before the window was first shown.
    public static func refreshFolderOverrides() {
        model?.refreshFolderOverrides()
    }

    /// The player switched the wheel mode (SmartShift): the row follows. Nothing before the window was first shown.
    public static func wheelFreeSpinDidChange() {
        store?.wheelFreeSpinDidChange()
    }
}
