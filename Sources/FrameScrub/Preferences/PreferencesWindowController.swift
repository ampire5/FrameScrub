import AppKit
import FrameScrubCore
import SwiftUI

/// The tabs of the settings window. Every tab keeps its own hosting view in the window and a switch only hides and shows
/// them: SwiftUI's `TabView` (and `NSTabViewController`) detach the old tab and attach the new one, and each attach made
/// SwiftUI evaluate the whole form again, a visible lag on slower Macs. The tabs that are not showing are built one per
/// run loop turn after the window is up, so a switch finds them ready.
final class PreferencesTabsController: NSViewController {
    static let contentSize = NSSize(width: 560, height: 540)
    private static let barHeight: CGFloat = 40

    private let model: PreferencesModel
    private var feeds: [PreferencesView.Tab: PreferencesTabFeed] = [:]
    private let tabs: [PreferencesView.Tab]
    private let mouseTab: AnyView?
    private let control = NSSegmentedControl()
    private let container = NSView()
    private var hosts: [PreferencesView.Tab: NSHostingController<PreferencesView>] = [:]
    private var selected = PreferencesView.Tab.general
    private var warmed = false

    init(model: PreferencesModel, mouseTab: AnyView?) {
        self.model = model
        self.mouseTab = mouseTab
        tabs = PreferencesView.Tab.allCases.filter { $0 != .mouse || mouseTab != nil }
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let size = NSSize(width: Self.contentSize.width, height: Self.contentSize.height + Self.barHeight)
        let root = NSView(frame: NSRect(origin: .zero, size: size))
        control.segmentCount = tabs.count
        for (index, tab) in tabs.enumerated() { control.setLabel(tab.title, forSegment: index) }
        control.selectedSegment = 0
        control.target = self
        control.action = #selector(segmentChosen(_:))
        control.sizeToFit()
        control.frame.origin = NSPoint(x: (size.width - control.frame.width) / 2, y: size.height - Self.barHeight + (Self.barHeight - control.frame.height) / 2)
        control.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin]
        container.frame = NSRect(origin: .zero, size: Self.contentSize)
        container.autoresizingMask = [.width, .height]
        root.addSubview(container)
        root.addSubview(control)
        view = root
        show(.general)
    }

    @objc private func segmentChosen(_ sender: NSSegmentedControl) { show(tabs[sender.selectedSegment]) }

    private func host(_ tab: PreferencesView.Tab) -> NSHostingController<PreferencesView> {
        if let host = hosts[tab] { return host }
        let feed = PreferencesTabFeed(model: model)
        feeds[tab] = feed
        let host = NSHostingController(rootView: PreferencesView(feed: feed, tab: tab, mouseTab: mouseTab))
        host.sizingOptions = []
        addChild(host)
        host.view.frame = container.bounds
        host.view.autoresizingMask = [.width, .height]
        host.view.isHidden = true
        container.addSubview(host.view)
        hosts[tab] = host
        return host
    }

    private func show(_ tab: PreferencesView.Tab) {
        selected = tab
        let shown = host(tab)
        for (other, host) in hosts where other != tab { host.view.isHidden = true; feeds[other]?.isShowing = false }
        shown.view.isHidden = false
        feeds[tab]?.isShowing = true
        control.selectedSegment = tabs.firstIndex(of: tab) ?? 0
    }

    /// Builds the other tabs, one per run loop turn, once the first one is on screen.
    func warmUp() {
        guard !warmed else { return }
        warmed = true
        var pending = tabs.filter { $0 != selected }
        func next() {
            guard !pending.isEmpty else { return }
            let view = host(pending.removeFirst()).view
            view.layoutSubtreeIfNeeded()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: next)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: next)
    }
}

/// The single settings window (⌘,).
final class PreferencesWindowController: NSWindowController {
    private let tabs: PreferencesTabsController

    init(store: PreferencesStore, mouseTab: AnyView? = nil) {
        tabs = PreferencesTabsController(model: PreferencesModel(store: store), mouseTab: mouseTab)
        let window = NSWindow(contentViewController: tabs)
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
        tabs.warmUp()
    }
}
