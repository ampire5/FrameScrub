import AppKit
import FrameScrubCore
import SwiftUI

/// The single settings window (⌘,).
final class PreferencesWindowController: NSWindowController {
    init(store: PreferencesStore, mouseTab: AnyView? = nil) {
        let model = PreferencesModel(store: store)
        let host = NSHostingController(rootView: PreferencesView(model: model, mouseTab: mouseTab))
        let window = NSWindow(contentViewController: host)
        window.title = "Settings"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false   // AppDelegate keeps this controller and reopens the window
        window.center()
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}
