import AppKit
import FrameScrubCore
import SlotChrome

/// The window's three slots (left, right, bottom; spec "slots"): what each holds, where it goes (`SlotLayout`), showing
/// and hiding them (chords, menus, the edge and its tongue, auto-hide), and the plugin pages they hold — one page per slot, so
/// the same plugin in two slots is two pages. The controller sets the slots' frames itself and tells the window where
/// the video goes (`onLayout`); nothing shows a slot by itself (spec §3.7).
@MainActor final class SlotsController {
    /// The video's rect and the visible part of it, in container points, whenever either changes.
    var onLayout: ((_ video: CGRect, _ visible: CGRect) -> Void)?
    /// A new page was made for a slot: the window wires its callbacks.
    var configurePage: ((PluginPanel) -> Void)?
    /// A slot's setting changed (written to `framescrub.conf` by the window).
    var onPersist: ((SlotEdge, SlotSetting) -> Void)?
    /// A short message for the OSD.
    var onMessage: ((String) -> Void)?
    /// Which pages are shown changed, or a page's slot (mode, backdrop, focus): keys and state go to the shown pages.
    var onPagesChanged: (() -> Void)?
    /// A slot holding the keyboard hid: keys go back to the player.
    var onFocusVideo: (() -> Void)?
    /// A page left its slot for good (cleared, replaced, its plugin gone): what it declared is void.
    var onPageDropped: ((PluginPanel) -> Void)?
    /// The band at the container's top that the side slots keep clear: the title bar and toolbar over the content.
    var topInset: CGFloat = 0 {
        didSet { if topInset != oldValue { applyLayout(revealing: nil, animated: false) } }
    }

    let playlistView: PlaylistPanelView

    @MainActor private final class Slot {
        let edge: SlotEdge
        let view: SlotView
        let tongue: SlotTongueView
        /// `contents` is always `tabs` turned so the shown tab is first (`sync`), as it is saved.
        var setting: SlotSetting
        /// The tabs in the order the capsule shows them (stable while tabs are switched).
        var tabs: [SlotContent]
        var shownTab: SlotContent?
        /// The plugin pages of its tabs by plugin name, made when a tab is first shown, and the URL its entry had when
        /// the page loaded it.
        var pages: [String: (panel: PluginPanel, entryURL: URL?)] = [:]
        /// Tabs a `framescrub://` link added for this run: not saved.
        var transient: Set<SlotContent> = []
        var reveal = EdgeReveal()
        var clock: AutoHideClock
        /// When the slot was last shown, for the layout's "newest demotes first".
        var shownOrder = 0
        var demoted = false

        init(edge: SlotEdge, setting: SlotSetting) {
            self.edge = edge
            view = SlotView(edge: edge)
            tongue = SlotTongueView(edge: edge)
            self.setting = setting
            tabs = setting.contents
            shownTab = setting.contents.first
            clock = AutoHideClock(mode: setting.autoHide)
        }

        /// The shown tab's page.
        var page: PluginPanel? {
            guard case let .plugin(name) = shownTab else { return nil }
            return pages[name]?.panel
        }

        func holds(_ page: PluginPanel) -> Bool { pages.values.contains { $0.panel === page } }

        /// `setting.contents` from the tabs, the shown one first.
        func sync() {
            guard let shownTab, let i = tabs.firstIndex(of: shownTab) else {
                setting.contents = tabs
                return
            }
            setting.contents = Array(tabs[i...] + tabs[..<i])
        }
    }

    private let container: NSView
    /// Slot views go above this one (the video, or a view covering it such as the start screen).
    private let above: NSView
    private var slots: [SlotEdge: Slot] = [:]
    private var plugins: [PluginEntry]
    /// A page a `framescrub://` link brought (`plugin=` in the link), shown as the plugin named `Plugin`.
    private var linkPlugin: PluginEntry?
    private var showCounter = 0
    private var lastVideo: CGRect?
    private var lastVisible: CGRect?
    private var autoHideTimer: Timer?
    private var monitor: Any?
    private var globalMonitor: Any?
    /// A slot's menu is open: auto-hide waits.
    private var menuOpen = false
    /// The OSD said the window is too small for these pinned slots; said again only when the set changes.
    private var reportedDemotions: Set<SlotEdge> = []
    /// `slot-reveal-distance`: how near a side edge the pointer brings a hidden slot.
    private var revealBand = CGFloat(EdgeReveal.sideBand)

    /// Makes the slots; `start` fills them once the callbacks are set.
    init(container: NSView, above: NSView, config: Config, playlistView: PlaylistPanelView) {
        self.container = container
        self.above = above
        self.playlistView = playlistView
        plugins = config.plugins
        revealBand = CGFloat(config.slotRevealDistance)
        var playlistTaken = false
        for edge in SlotEdge.allCases {
            var setting = (config.slots[edge] ?? SlotSetting.default(for: edge)).clamped(for: edge)
            if setting.contents.contains(.playlist) {
                // One playlist: the first slot that names it keeps it.
                if playlistTaken { setting.contents.removeAll { $0 == .playlist } }
                playlistTaken = true
            }
            let slot = Slot(edge: edge, setting: setting)
            slots[edge] = slot
            slot.view.translatesAutoresizingMaskIntoConstraints = true
            container.addSubview(slot.view, positioned: .above, relativeTo: above)
            wire(slot)
        }
    }

    /// Puts each slot's view in (making the pages), and shows the pinned slots that were shown; overlay slots start
    /// hidden.
    func start() {
        for slot in orderedSlots { refresh(slot) }
        for slot in orderedSlots {
            container.addSubview(slot.tongue)   // above everything: the tongue must take its click
            slot.tongue.onClick = { [weak self, weak slot] in
                guard let self, let slot, !slot.view.isShown else { return }
                hideTongue(slot)
                show(slot, focus: false)
            }
        }
        for slot in orderedSlots where slot.setting.shown {
            if slot.setting.mode == .pinned && !slot.tabs.isEmpty {
                showCounter += 1
                slot.shownOrder = showCounter
                slot.view.setShown(true, animated: false)
                updatePagesShown(slot)
            } else {
                slot.setting.shown = false
            }
        }
        applyLayout(revealing: nil, animated: false)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .leftMouseDown,
                                                              .leftMouseUp, .rightMouseDown, .rightMouseUp,
                                                              .otherMouseDown, .otherMouseUp]) { [weak self] event in
            MainActor.assumeIsolated { self?.pointerEvent(event) }
            return event
        }
        // While the app is in the background it gets no pointer events of its own; the player window may still be in sight.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            MainActor.assumeIsolated { self?.backgroundPointerEvent() }
        }
    }

    isolated deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        autoHideTimer?.invalidate()
    }

    private var orderedSlots: [Slot] { SlotEdge.allCases.compactMap { slots[$0] } }

    // MARK: What the window asks

    /// Every page the slots hold, shown or not.
    var pages: [PluginPanel] { orderedSlots.flatMap { $0.pages.values.map(\.panel) } }

    /// The pages whose slot is on screen, oldest shown first.
    var shownPages: [PluginPanel] {
        orderedSlots.filter { $0.view.isShown }.sorted { $0.shownOrder < $1.shownOrder }.compactMap(\.page)
    }

    func page(withToken token: Int) -> PluginPanel? { pages.first { $0.token == token } }

    /// Where `page` is shown, for its `panel` state.
    func panelInfo(for page: PluginPanel) -> PanelInfo? {
        guard let slot = orderedSlots.first(where: { $0.holds(page) }) else { return nil }
        let mode = effectiveMode(slot)
        return PanelInfo(slot: slot.edge, mode: mode, backdrop: mode == .pinned ? .dark : slot.setting.backdrop,
                         shown: slot.view.isShown && slot.page === page, focused: slot.view.holds(container.window?.firstResponder as? NSView))
    }

    /// The pointer is over a shown slot (not the video).
    var isPointerOverShownSlot: Bool {
        guard let window = container.window else { return false }
        let point = container.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        return orderedSlots.contains { $0.view.isShown && $0.view.frame.contains(point) }
    }

    /// Whether the playlist is in a shown slot.
    var isPlaylistShown: Bool { orderedSlots.contains { $0.shownTab == .playlist && $0.view.isShown } }

    // MARK: Showing and hiding

    /// ⌃⌘← / ⌃⌘→ / ⌃⌘↓ and View › Slots: shows the slot with the keyboard (an empty one opens its "+" menu), or hides it.
    func toggle(_ edge: SlotEdge) {
        guard let slot = slots[edge] else { return }
        if slot.view.isShown { hide(slot) } else { show(slot, focus: true) }
    }

    /// F8 / TAB (`toggle-playlist`): the slot holding the playlist, its tab shown; without one, the playlist becomes a tab
    /// of the first empty slot (right, left, bottom), else of the right slot.
    func togglePlaylist() {
        if let slot = orderedSlots.first(where: { $0.tabs.contains(.playlist) }) {
            if slot.view.isShown && slot.shownTab == .playlist { hide(slot); return }
            select(.playlist, in: slot)
            show(slot, focus: false)
            return
        }
        guard let slot = firstEmptySlot ?? slots[.right] else { return }
        addTab(.playlist, to: slot)
        show(slot, focus: false)
    }

    /// Shows the playlist's slot (placing the playlist as `togglePlaylist` does) and gives it the keyboard's filter.
    func showPlaylistForFilter() {
        if !isPlaylistShown { togglePlaylist() }
        guard isPlaylistShown else { return }
        playlistView.beginFilter()
    }

    /// ⌥⌘P: the first slot with a plugin tab, that tab shown; without one, the first plugin goes into the first empty slot.
    func togglePlugin(focus: Bool = false) {
        if let slot = orderedSlots.first(where: { $0.tabs.contains(where: Self.isPlugin) }) {
            if slot.view.isShown && !focus && slot.shownTab.map(Self.isPlugin) == true { hide(slot); return }
            if slot.shownTab.map(Self.isPlugin) != true, let tab = slot.tabs.first(where: Self.isPlugin) {
                select(tab, in: slot)
            }
            show(slot, focus: focus)
            return
        }
        guard let first = allPlugins.first else {
            onMessage?("No plugin page: add plugin=Name | URL to framescrub.conf, or open a link with plugin=")
            return
        }
        guard let slot = firstEmptySlot else {
            onMessage?("Every slot is taken: choose \(first.name) in a slot's + menu")
            return
        }
        addTab(.plugin(name: first.name), to: slot)
        show(slot, focus: focus)
    }

    private static func isPlugin(_ content: SlotContent) -> Bool {
        if case .plugin = content { return true }
        return false
    }

    /// A `framescrub://` link's page: shown in the first page a slot holds (its tab shown), or in a tab of its own (for
    /// this run) in an empty slot, else the right one.
    @discardableResult
    func showLinkPage(_ url: URL) -> Bool {
        guard PluginPageSource.link.accepts(url) else { return false }
        for slot in orderedSlots {
            guard let (name, entry) = slot.pages.first(where: { slot.shownTab == .plugin(name: $0.key) })
                    ?? slot.pages.first else { continue }
            entry.panel.load(url, from: .link)
            select(.plugin(name: name), in: slot)
            show(slot, focus: false)
            return true
        }
        linkPlugin = PluginEntry(name: SlotDefaults.linkPluginName, url: url)
        guard let slot = firstEmptySlot ?? slots[.right] else { return false }
        let tab = SlotContent.plugin(name: SlotDefaults.linkPluginName)
        if !slot.tabs.contains(tab) { slot.transient.insert(tab) }
        addTab(tab, to: slot)
        slot.page?.load(url, from: .link)
        show(slot, focus: false)
        return true
    }

    /// A click on the video: the overlay slots go. False when none was shown (the click is the video's then).
    @discardableResult
    func hideOverlays() -> Bool {
        let shown = orderedSlots.filter { $0.view.isShown && effectiveMode($0) == .overlay }
        for slot in shown { hide(slot) }
        return !shown.isEmpty
    }

    /// The page asked to hide (`hide()` in the bridge).
    func hide(page: PluginPanel) {
        guard let slot = orderedSlots.first(where: { $0.page === page }), slot.view.isShown else { return }
        hide(slot)
    }

    /// The page started something playing (`open`, `playlist`): its overlay slot goes when it hides after a choice.
    /// The plugin page under the pointer, in a slot on screen.
    var pageUnderPointer: PluginPanel? {
        orderedSlots.lazy.compactMap { $0.page }.first { $0.hasPointer }
    }

    func pageChosePlay(_ page: PluginPanel) {
        guard let slot = orderedSlots.first(where: { $0.holds(page) }) else { return }
        hideAfterChoice(slot)
    }

    /// The playlist opened a file: its overlay slot goes when it hides after a choice.
    func playlistChosePlay() {
        guard let slot = orderedSlots.first(where: { $0.tabs.contains(.playlist) }) else { return }
        hideAfterChoice(slot)
    }

    /// Esc in a page that left it unhandled, or in the playlist's filter: an overlay slot hides. True when it did.
    func escape(in view: NSView) -> Bool {
        guard let slot = orderedSlots.first(where: { $0.view.holds(view) }), slot.view.isShown,
              effectiveMode(slot) == .overlay else { return false }
        hide(slot)
        return true
    }

    private func hideAfterChoice(_ slot: Slot) {
        guard slot.view.isShown, effectiveMode(slot) == .overlay, slot.clock.hidesOnChoice else { return }
        hide(slot)
    }

    private var firstEmptySlot: Slot? {
        [SlotEdge.right, .left, .bottom].compactMap { slots[$0] }.first { $0.tabs.isEmpty }
    }

    private func show(_ slot: Slot, focus: Bool) {
        if !slot.view.isShown {
            showCounter += 1
            slot.shownOrder = showCounter
            slot.setting.shown = true
            updatePagesShown(slot)
            hideTongue(slot)
            slot.reveal.reset()
            applyLayout(revealing: slot)
            slot.clock.shown(pointerInside: isPointer(in: slot), now: Self.now)
            persist(slot)
            onPagesChanged?()
            updateAutoHideTimer()
        }
        if slot.tabs.isEmpty {
            DispatchQueue.main.async { [weak self, weak slot] in
                guard let self, let slot, slot.view.isShown else { return }
                popUp(plusMenu(for: slot), from: nil, in: slot)
            }
        } else if focus {
            if let page = slot.page { page.focus() } else if slot.shownTab == .playlist { playlistView.beginFilter() }
        }
    }

    private func hide(_ slot: Slot) {
        guard slot.view.isShown else { return }
        let hadFocus = holdsFocus(slot)
        slot.setting.shown = false
        slot.view.setShown(false, animated: true) { [weak self] in self?.onPagesChanged?() }
        updatePagesShown(slot)
        applyLayout(revealing: nil)
        persist(slot)
        if hadFocus { onFocusVideo?() }
        onPagesChanged?()
        updateAutoHideTimer()
    }

    // MARK: Layout

    /// The container's size changed.
    func containerDidLayout() {
        applyLayout(revealing: nil, animated: false)
    }

    /// Lays out the shown slots; `revealing` is the slot that has just been shown and slides in. A pinned slot changes
    /// the video once, when its slide ends; an overlay slot never does.
    private func applyLayout(revealing: Slot?, animated: Bool = true) {
        guard container.bounds.width >= 1, container.bounds.height >= 1 else {   // not laid out yet
            revealing?.view.setShown(true, animated: false)
            return
        }
        let shown = orderedSlots.filter { $0.view.isShown || $0 === revealing }
        var sizes: [SlotEdge: (mode: SlotMode, size: CGFloat)] = [:]
        for slot in shown { sizes[slot.edge] = (slot.setting.mode, CGFloat(slot.setting.size)) }
        let layout = SlotLayout.compute(.init(container: container.bounds, slots: sizes,
                                              order: shown.sorted { $0.shownOrder < $1.shownOrder }.map(\.edge),
                                              topInset: topInset))
        var modesChanged = false
        for slot in shown {
            guard let rect = layout.slots[slot.edge] else { continue }
            if slot.view.frame != rect { slot.view.frame = rect }
            let mode = layout.effectiveMode[slot.edge] ?? slot.setting.mode
            if slot.view.mode != mode { slot.view.mode = mode; modesChanged = true }
            slot.view.backdrop = slot.setting.backdrop
            slot.demoted = layout.demoted.contains(slot.edge)
        }
        let demoted = Set(layout.demoted)
        if !demoted.isEmpty, !demoted.isSubset(of: reportedDemotions) {
            onMessage?("Not enough room beside the video: the slot lies over it")
        }
        reportedDemotions = demoted
        var visible = layout.video
        for (edge, rect) in layout.slots where layout.effectiveMode[edge] == .overlay {
            switch edge {
            case .left: visible.size.width -= rect.maxX - visible.minX; visible.origin.x = rect.maxX
            case .right: visible.size.width = rect.minX - visible.minX
            case .bottom: visible.size.height -= rect.maxY - visible.minY; visible.origin.y = rect.maxY
            }
        }
        let report = { [weak self] in
            guard let self, layout.video != lastVideo || visible != lastVisible else { return }
            lastVideo = layout.video
            lastVisible = visible
            onLayout?(layout.video, visible)
        }
        if let revealing, animated {
            let pinned = layout.effectiveMode[revealing.edge] == .pinned
            if !pinned { report() }   // the visible part shrinks at once; the video stays as it is
            revealing.view.setShown(true, animated: true) { if pinned { report() } }
        } else {
            revealing?.view.setShown(true, animated: false)
            report()
        }
        if modesChanged { onPagesChanged?() }
    }

    private func effectiveMode(_ slot: Slot) -> SlotMode { slot.demoted ? .overlay : slot.setting.mode }

    // MARK: Contents

    private var allPlugins: [PluginEntry] {
        guard let linkPlugin, !plugins.contains(where: { $0.name == linkPlugin.name }) else { return plugins }
        return plugins + [linkPlugin]
    }

    /// Settings changed: the reveal distance, the plugin list (a slot whose plugin moved to another URL loads it; one that vanished says so).
    func configChanged(_ config: Config) {
        plugins = config.plugins
        revealBand = CGFloat(config.slotRevealDistance)
        for slot in orderedSlots { refresh(slot) }
    }

    private func holdsFocus(_ slot: Slot) -> Bool {
        slot.view.holds(container.window?.firstResponder as? NSView)
    }

    private static func tabID(_ content: SlotContent) -> String {
        switch content {
        case .empty: ""
        case .playlist: "playlist"
        case let .plugin(name): "plugin:" + name
        }
    }

    private func content(ofTab id: String, in slot: Slot) -> SlotContent? { slot.tabs.first { Self.tabID($0) == id } }

    /// Shows `content`'s tab (one the slot has).
    private func select(_ content: SlotContent, in slot: Slot) {
        guard slot.tabs.contains(content), slot.shownTab != content else { return }
        let hadFocus = holdsFocus(slot)
        slot.shownTab = content
        changed(slot, hadFocus: hadFocus)
    }

    /// Adds `content` as a tab of `slot` (or finds it there) and shows it. The playlist leaves the slot that had it.
    private func addTab(_ content: SlotContent, to slot: Slot) {
        guard content != .empty else { return }
        if content == .playlist {
            for other in orderedSlots where other !== slot && other.tabs.contains(.playlist) {
                removeTab(.playlist, from: other, dropPage: true)
            }
        }
        let hadFocus = holdsFocus(slot)
        if !slot.tabs.contains(content) { slot.tabs.append(content) }
        slot.shownTab = content
        changed(slot, hadFocus: hadFocus)
    }

    /// Closes a tab; the next one (or the one before the last) shows. Its page goes, unless it is being moved.
    private func removeTab(_ content: SlotContent, from slot: Slot, dropPage: Bool) {
        guard let i = slot.tabs.firstIndex(of: content) else { return }
        let hadFocus = holdsFocus(slot)
        if content == .playlist { slot.view.capsule.endFilter() }
        slot.tabs.remove(at: i)
        slot.transient.remove(content)
        if slot.shownTab == content { slot.shownTab = slot.tabs.isEmpty ? nil : slot.tabs[min(i, slot.tabs.count - 1)] }
        if dropPage, case let .plugin(name) = content, let page = slot.pages.removeValue(forKey: name) {
            onPageDropped?(page.panel)
        }
        changed(slot, hadFocus: hadFocus)
    }

    /// Every tab closed (View › Slots › Clear Slot).
    private func clear(_ slot: Slot) {
        for tab in slot.tabs { removeTab(tab, from: slot, dropPage: true) }
    }

    /// Moves a tab, with its live page, to `target`, where it shows.
    private func moveTab(_ content: SlotContent, from slot: Slot, to target: Slot) {
        let hadFocus = holdsFocus(slot) || holdsFocus(target)
        if case let .plugin(name) = content, let page = slot.pages.removeValue(forKey: name) {
            if let theirs = target.pages[name], theirs.panel !== page.panel {
                onPageDropped?(page.panel)   // the target has this plugin already: its page stays
            } else {
                target.pages[name] = page
            }
        }
        let transient = slot.transient.contains(content)
        removeTab(content, from: slot, dropPage: false)
        if transient { target.transient.insert(content) }
        addTab(content, to: target)
        if slot.tabs.isEmpty, slot.view.isShown { hide(slot) }
        // Taking the view out of the window took the keyboard from it: the moved one gets it back.
        if hadFocus { onFocusVideo?() }
        show(target, focus: hadFocus)
    }

    /// After the tabs changed: the views, the capsule, saving, the pages' state.
    private func changed(_ slot: Slot, hadFocus: Bool) {
        slot.sync()
        refresh(slot)
        persist(slot)
        if hadFocus && !holdsFocus(slot) { onFocusVideo?() }
        onPagesChanged?()
    }

    /// Puts the slot's views in: the playlist if it is a tab, the pages made so far, and the shown tab's page (made and
    /// loaded the first time, loaded again when its entry's URL changed); a note when the shown plugin is not in the
    /// config. Pages of closed tabs go.
    private func refresh(_ slot: Slot) {
        slot.view.note = nil
        for (name, page) in slot.pages where !slot.tabs.contains(.plugin(name: name)) {
            slot.pages[name] = nil
            onPageDropped?(page.panel)
        }
        if case let .plugin(name) = slot.shownTab { makePage(name, in: slot) }
        var views: [String: NSView] = [:]
        if slot.tabs.contains(.playlist) { views[Self.tabID(.playlist)] = playlistView }
        for (name, page) in slot.pages { views[Self.tabID(.plugin(name: name))] = page.panel }
        let shownID = slot.shownTab.map(Self.tabID)
        slot.view.setViews(views, shown: shownID.flatMap { views[$0] == nil ? nil : $0 })
        slot.view.capsule.tabs = slot.tabs.map { tab(for: $0, selected: $0 == slot.shownTab) }
        updatePagesShown(slot)
    }

    private func tab(for content: SlotContent, selected: Bool) -> SlotTab {
        switch content {
        case .empty, .playlist:
            SlotTab(id: Self.tabID(.playlist), symbol: "play.rectangle", letter: nil, name: "Playlist", selected: selected)
        case let .plugin(name):
            SlotTab(id: Self.tabID(content), symbol: nil, letter: name.first.map { String($0).uppercased() }, name: name,
                    selected: selected)
        }
    }

    private func makePage(_ name: String, in slot: Slot) {
        guard let entry = allPlugins.first(where: { $0.name == name }) else {
            if let page = slot.pages.removeValue(forKey: name) { onPageDropped?(page.panel) }
            slot.view.note = "Plugin “\(name)” is not in framescrub.conf"
            return
        }
        var record = slot.pages[name] ?? {
            let page = PluginPanel()
            configurePage?(page)
            return (page, nil)
        }()
        if record.panel.url == nil || record.entryURL != entry.url {   // a link's page stays until the entry changes
            record.entryURL = entry.url
            if !record.panel.load(entry.url, from: entry == linkPlugin ? .link : .settings) {
                slot.view.note = "Cannot show \(entry.url.absoluteString)"
            }
        }
        slot.pages[name] = record
    }

    /// Only the shown tab's page of a shown slot counts as shown (its keys and state); the others wait hidden.
    private func updatePagesShown(_ slot: Slot) {
        for (name, page) in slot.pages {
            page.panel.isShownInSlot = slot.view.isShown && slot.shownTab == .plugin(name: name)
        }
    }

    // MARK: Menus

    private func wire(_ slot: Slot) {
        let view = slot.view
        view.onPlus = { [weak self, weak slot] button in
            guard let self, let slot else { return }
            popUp(plusMenu(for: slot), from: button, in: slot)
        }
        view.capsule.onCapsuleMenu = { [weak self, weak slot] in
            guard let self, let slot else { return nil }
            return capsuleMenu(for: slot)
        }
        view.capsule.onTabMenu = { [weak self, weak slot] id in
            guard let self, let slot, let content = content(ofTab: id, in: slot) else { return nil }
            return tabMenu(for: slot, content: content)
        }
        view.capsule.onSelectTab = { [weak self, weak slot] id in
            guard let self, let slot, let content = content(ofTab: id, in: slot) else { return }
            select(content, in: slot)
        }
        view.capsule.onPlus = { [weak self, weak slot] button in
            guard let self, let slot else { return }
            popUp(plusMenu(for: slot), from: button, in: slot)
        }
        view.capsule.onPin = { [weak self, weak slot] in
            guard let self, let slot else { return }
            togglePin(slot)
        }
        view.capsule.onBackdrop = { [weak self, weak slot] in
            guard let self, let slot else { return }
            cycleBackdrop(slot)
        }
        view.capsule.onMenuTracking = { [weak self] open in self?.menuOpen = open }
        view.capsule.onHide = { [weak self, weak slot] in
            guard let self, let slot else { return }
            hide(slot)
        }
        view.onResize = { [weak self, weak slot] size in
            guard let self, let slot else { return }
            let range = slot.edge.sizeRange
            let clamped = min(max(Int(size.rounded()), range.lowerBound), range.upperBound)
            guard clamped != slot.setting.size else { return }
            slot.setting.size = clamped
            applyLayout(revealing: nil, animated: false)
        }
        view.onResizeEnd = { [weak self, weak slot] in
            guard let self, let slot else { return }
            persist(slot)
        }
    }

    /// The slot that menu commands (View › Slots) act on: the one with the keyboard, else the newest shown one.
    private var currentSlot: Slot? {
        let responder = container.window?.firstResponder as? NSView
        return orderedSlots.first { $0.view.isShown && $0.view.holds(responder) }
            ?? orderedSlots.filter(\.view.isShown).max { $0.shownOrder < $1.shownOrder }
    }

    /// View › Slots › Pin / Float.
    func togglePinOfCurrent() { currentSlot.map(togglePin) }
    /// View › Slots › Next Backdrop.
    func cycleBackdropOfCurrent() { currentSlot.map(cycleBackdrop) }
    /// View › Slots › Clear Slot.
    func clearCurrent() {
        guard let slot = currentSlot else { return }
        clear(slot)
    }

    private func togglePin(_ slot: Slot) {
        slot.setting.mode = slot.setting.mode == .pinned ? .overlay : .pinned
        persist(slot)
        applyLayout(revealing: nil, animated: false)
        updateAutoHideTimer()
        onPagesChanged?()
    }

    private func cycleBackdrop(_ slot: Slot) {
        if effectiveMode(slot) == .pinned {
            onMessage?("A pinned slot is always dark")
            return
        }
        slot.setting.backdrop = slot.setting.backdrop.next
        slot.view.backdrop = slot.setting.backdrop
        persist(slot)
        onMessage?("Backdrop: \(Self.title(of: slot.setting.backdrop))")
        onPagesChanged?()
    }

    private static func title(of backdrop: SlotBackdrop) -> String {
        switch backdrop {
        case .dark: "Dark"
        case .glass: "Glass"
        case .clear: "Clear glass"
        }
    }

    private static func title(of edge: SlotEdge) -> String {
        switch edge {
        case .left: "Left"
        case .right: "Right"
        case .bottom: "Bottom"
        }
    }

    /// The "+" (of an empty slot, or after the tabs): the playlist (moved here from another slot) and the plugins; a view the
    /// slot has is ticked and shows.
    private func plusMenu(for slot: Slot) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let playlistElsewhere = orderedSlots.contains { $0 !== slot && $0.tabs.contains(.playlist) }
        let playlist = menu.addItem(withTitle: "Playlist", action: nil, keyEquivalent: "")
        playlist.state = slot.tabs.contains(.playlist) ? .on : .off
        if playlistElsewhere { playlist.toolTip = "Moves the playlist here from another slot" }
        playlist.handler = { [weak self, weak slot] in
            guard let self, let slot else { return }
            choose(.playlist, for: slot)
        }
        menu.addItem(.separator())
        if allPlugins.isEmpty {
            let none = menu.addItem(withTitle: "No plugins: add plugin=Name | URL to framescrub.conf", action: nil,
                                    keyEquivalent: "")
            none.isEnabled = false
        }
        for entry in allPlugins {
            let item = menu.addItem(withTitle: entry.name, action: nil, keyEquivalent: "")
            item.state = slot.tabs.contains(.plugin(name: entry.name)) ? .on : .off
            item.handler = { [weak self, weak slot] in
                guard let self, let slot else { return }
                choose(.plugin(name: entry.name), for: slot)
            }
        }
        return menu
    }

    private func choose(_ content: SlotContent, for slot: Slot) {
        addTab(content, to: slot)
        show(slot, focus: true)
    }

    /// A right click on a tab: reload its page, move it to another slot, close it.
    private func tabMenu(for slot: Slot, content: SlotContent) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        if case let .plugin(name) = content, let page = slot.pages[name]?.panel {
            let reload = menu.addItem(withTitle: "Reload Page", action: nil, keyEquivalent: "r")   // ⌘R in the page too
            reload.handler = { [weak page] in page?.reload() }
            menu.addItem(.separator())
        }
        for edge in SlotEdge.allCases where edge != slot.edge {
            let item = menu.addItem(withTitle: "Move to \(Self.title(of: edge)) Slot", action: nil, keyEquivalent: "")
            item.handler = { [weak self, weak slot] in
                guard let self, let slot, let target = slots[edge] else { return }
                moveTab(content, from: slot, to: target)
            }
        }
        menu.addItem(.separator())
        let close = menu.addItem(withTitle: "Close Tab", action: nil, keyEquivalent: "")
        close.handler = { [weak self, weak slot] in
            guard let self, let slot else { return }
            removeTab(content, from: slot, dropPage: true)
        }
        return menu
    }

    /// A right click on the capsule's empty part: when the slot hides by itself, how it comes from its edge, clearing it.
    private func capsuleMenu(for slot: Slot) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let heading = menu.addItem(withTitle: "Hide by Itself", action: nil, keyEquivalent: "")
        heading.isEnabled = false
        let choices: [(SlotAutoHide, String)] = [(.afterChoice, "After Choosing Something to Play"),
                                                 (.mouseLeaves, "When the Pointer Leaves"), (.manual, "Only When Asked")]
        for (mode, title) in choices {
            let item = menu.addItem(withTitle: title, action: nil, keyEquivalent: "")
            item.state = slot.setting.autoHide == mode ? .on : .off
            item.indentationLevel = 1
            item.isEnabled = slot.setting.mode == .overlay
            item.handler = { [weak self, weak slot] in
                guard let self, let slot else { return }
                slot.setting.autoHide = mode
                slot.clock = AutoHideClock(mode: mode)
                slot.clock.pointerInside(isPointer(in: slot), now: Self.now)
                persist(slot)
                updateAutoHideTimer()
            }
        }
        menu.addItem(.separator())
        let revealHeading = menu.addItem(withTitle: "Show from the Edge", action: nil, keyEquivalent: "")
        revealHeading.isEnabled = false
        for (reveal, title) in [(SlotReveal.atOnce, "When the Pointer Touches It"), (.tongue, "With a Click on Its Tongue")] {
            let item = menu.addItem(withTitle: title, action: nil, keyEquivalent: "")
            item.state = slot.setting.reveal == reveal ? .on : .off
            item.indentationLevel = 1
            item.isEnabled = slot.setting.mode == .overlay
            item.handler = { [weak self, weak slot] in
                guard let self, let slot else { return }
                slot.setting.reveal = reveal
                slot.reveal.reset()
                hideTongue(slot)
                persist(slot)
            }
        }
        if !slot.tabs.isEmpty {
            menu.addItem(.separator())
            let clear = menu.addItem(withTitle: "Clear Slot", action: nil, keyEquivalent: "")
            clear.handler = { [weak self, weak slot] in
                guard let self, let slot else { return }
                self.clear(slot)
            }
        }
        return menu
    }

    private func popUp(_ menu: NSMenu, from button: NSView?, in slot: Slot) {
        menuOpen = true
        defer { menuOpen = false }
        if let button {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 2), in: button)
        } else {
            let view = slot.view
            menu.popUp(positioning: nil, at: NSPoint(x: view.bounds.midX - 60, y: view.bounds.midY), in: view)
        }
    }

    // MARK: The edge

    private static var now: Double { ProcessInfo.processInfo.systemUptime }

    /// A hidden overlay slot with something in it comes from its edge: at once when the pointer touches the edge, or
    /// by a click on its tongue, which fades in as the pointer nears.
    private func pointerEvent(_ event: NSEvent) {
        guard event.window === container.window, container.window != nil else { return }
        reveal(at: container.convert(event.locationInWindow, from: nil))
    }

    /// The pointer over the player's window while the app is in the background (a Mac in use elsewhere, the player beside it):
    /// the edges answer as they do in front. Only when the window itself is what is under the pointer, not another window over it.
    private func backgroundPointerEvent() {
        guard !NSApp.isActive, let window = container.window, window.isVisible, window.occlusionState.contains(.visible) else { return }
        let screenPoint = NSEvent.mouseLocation
        guard window.frame.contains(screenPoint),
              NSWindow.windowNumber(at: screenPoint, belowWindowWithWindowNumber: 0) == window.windowNumber else { return }
        reveal(at: container.convert(window.convertPoint(fromScreen: screenPoint), from: nil))
    }

    /// `point` in the container: edges and tongues of the hidden overlay slots. A window that is not the key one still
    /// answers (another of the app's windows may be in front of the keyboard): only a sheet on it keeps the edges quiet.
    private func reveal(at point: CGPoint) {
        // Left, right, middle, back and forward only: a mouse or its driver can leave a higher button down in the HID
        // state for good (button 6 seen stuck system-wide, Mac Mouse Fix off or on, 2026-10-27), and the edges
        // would stay quiet until a reboot.
        let buttonHeld = NSEvent.pressedMouseButtons & 0b11111 != 0
        let bounds = container.bounds
        let quiet = container.window?.attachedSheet != nil
        for slot in orderedSlots {
            guard !quiet, !slot.view.isShown, !slot.tabs.isEmpty, slot.setting.mode == .overlay else {
                slot.reveal.reset()
                hideTongue(slot)
                continue
            }
            switch slot.setting.reveal {
            case .atOnce:
                hideTongue(slot)
                if slot.reveal.pointer(atEdge: EdgeReveal.isAt(slot.edge, point, in: bounds, band: revealBand), buttonHeld: buttonHeld) == .revealSlot {
                    show(slot, focus: false)
                }
            case .tongue:
                let overTongue = !slot.tongue.isHidden && slot.tongue.frame.contains(point)
                switch EdgeTongue.reaction(buttonHeld: buttonHeld, overTongue: overTongue) {
                case .follow: moveTongue(slot, toward: point, in: bounds)
                case .hide: hideTongue(slot)
                case .keep: break   // the press is on its way to the tongue's own mouseDown
                }
            }
        }
    }

    /// The tongue at the pointer's place along the edge, as visible as the pointer is near.
    private func moveTongue(_ slot: Slot, toward p: CGPoint, in b: CGRect) {
        let distance: CGFloat = switch slot.edge {
        case .left: p.x - b.minX
        case .right: b.maxX - p.x
        case .bottom: p.y - b.minY
        }
        let opacity = b.contains(p) ? EdgeTongue.opacity(distance: distance) : 0
        guard opacity > 0 else { hideTongue(slot); return }
        let t = SlotTongueView.hitThickness, l = EdgeTongue.length
        let tongue = slot.tongue
        switch slot.edge {
        case .left:
            tongue.frame = CGRect(x: b.minX, y: EdgeTongue.center(at: p.y, span: b.minY...b.maxY) - l / 2, width: t, height: l)
        case .right:
            tongue.frame = CGRect(x: b.maxX - t, y: EdgeTongue.center(at: p.y, span: b.minY...b.maxY) - l / 2, width: t,
                                  height: l)
        case .bottom:
            tongue.frame = CGRect(x: EdgeTongue.center(at: p.x, span: b.minX...b.maxX) - l / 2, y: b.minY, width: l, height: t)
        }
        tongue.alphaValue = opacity
        tongue.isHidden = false
    }

    private func hideTongue(_ slot: Slot) { slot.tongue.isHidden = true }

    // MARK: Auto-hide

    /// The pointer is in the slot, or gone out of the window across the slot's edge and not far.
    private func isPointer(in slot: Slot) -> Bool {
        guard let window = container.window else { return false }
        let point = container.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        return SlotHover.counts(point, slot: slot.view.frame, edge: slot.edge, window: container.bounds)
    }

    /// A timer runs only while an overlay slot that hides when the pointer leaves is shown.
    private func updateAutoHideTimer() {
        let needed = orderedSlots.contains {
            $0.view.isShown && effectiveMode($0) == .overlay && $0.setting.autoHide == .mouseLeaves
        }
        if needed && autoHideTimer == nil {
            autoHideTimer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.autoHideTick() }
            }
        } else if !needed {
            autoHideTimer?.invalidate()
            autoHideTimer = nil
        }
    }

    private func autoHideTick() {
        let now = Self.now
        for slot in orderedSlots where slot.view.isShown && effectiveMode(slot) == .overlay {
            slot.clock.pointerInside(isPointer(in: slot), now: now)
            slot.clock.setBusy(menuOpen || slot.view.isResizing || isTyping(in: slot))
            if slot.clock.shouldHide(now: now) { hide(slot) }
        }
    }

    /// Typing goes on in the slot: its page has a text field with the keyboard, or the playlist's filter has it.
    private func isTyping(in slot: Slot) -> Bool {
        guard holdsFocus(slot) else { return false }
        if let page = slot.page { return page.isTyping }
        return slot.shownTab == .playlist && playlistView.isEditingFilter
    }

    // MARK: Saving

    /// Saves the slot's setting: its tabs (the shown one first) without those a link added for this run.
    private func persist(_ slot: Slot) {
        var setting = slot.setting
        setting.contents.removeAll { slot.transient.contains($0) }
        if setting.contents.isEmpty { setting.shown = false }
        onPersist?(slot.edge, setting)
    }
}

private extension NSMenuItem {
    /// A closure run when the item is chosen.
    var handler: (() -> Void)? {
        get { (representedObject as? MenuHandler)?.run }
        set {
            let target = newValue.map(MenuHandler.init)
            representedObject = target
            self.target = target
            action = target == nil ? nil : #selector(MenuHandler.fire)
        }
    }
}

private final class MenuHandler: NSObject {
    let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
    @objc func fire() { run() }
}
