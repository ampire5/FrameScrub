import AppKit
import FrameScrubCore
import SlotChrome
import Slots

/// App adapter: the common host owns panels, FrameScrub owns playlist and trusted web pages.
@MainActor final class SlotsController {
    var onLayout: ((CGRect, CGRect) -> Void)?
    var configurePage: ((PluginPanel) -> Void)?
    var onPersist: ((SlotEdge, SlotSetting) -> Void)?
    var onMessage: ((String) -> Void)?
    var onPagesChanged: (() -> Void)?
    var onFocusVideo: (() -> Void)?
    var onPageDropped: ((PluginPanel) -> Void)?
    var topInset: CGFloat { get { host.topInset } set { host.topInset = newValue } }
    let playlistView: PlaylistPanelView
    private let host: Slots.SlotsController
    private var plugins: [PluginEntry]
    private var linkPlugin: PluginEntry?
    private var entryURLs: [ObjectIdentifier: URL] = [:]
    private var flashEnabled: Bool
    private static let playlist = SlotTabID(rawValue: "playlist")
    private static func id(_ name: String) -> SlotTabID { SlotTabID(rawValue: "plugin:" + name) }

    init(container: NSView, above: NSView, config: Config, playlistView: PlaylistPanelView) {
        self.playlistView = playlistView
        host = Slots.SlotsController(container: container, above: above)
        plugins = config.plugins; flashEnabled = config.slotFlash
        host.revealBand = CGFloat(config.slotRevealDistance)
        registerPlaylist()
        registerPlugins()
        var playlistTaken = false
        for edge in SlotEdge.allCases {
            var s = config.slots[edge] ?? .default(for: edge)
            if s.contents.contains(.playlist) {
                if playlistTaken { s.contents.removeAll { $0 == .playlist } }
                playlistTaken = true
            }
            host.configure(Self.configuration(s), edge: edge)
        }
        host.onLayout = { [weak self] in self?.onLayout?($0, $1) }
        host.onPersist = { [weak self] edge, state in self?.onPersist?(edge, Self.setting(state)) }
        host.onMessage = { [weak self] in self?.onMessage?($0) }
        host.onChanged = { [weak self] in self?.onPagesChanged?() }
        host.onFocusContent = { [weak self] in self?.onFocusVideo?() }
    }

    private static func configuration(_ s: SlotSetting) -> SlotConfiguration {
        SlotConfiguration(tabs: s.contents.compactMap {
            switch $0 { case .empty: nil; case .playlist: playlist; case .plugin(let name): id(name) }
        }, mode: s.mode, backdrop: s.backdrop, autoHide: s.autoHide, size: s.size, shown: s.shown, reveal: s.reveal)
    }
    private static func setting(_ c: SlotConfiguration) -> SlotSetting {
        var s = SlotSetting(content: .empty, mode: c.mode, backdrop: c.backdrop, autoHide: c.autoHide,
                            size: c.size, shown: c.shown, reveal: c.reveal)
        s.contents = c.tabs.compactMap {
            if $0 == playlist { return .playlist }
            if $0.rawValue.hasPrefix("plugin:") { return .plugin(name: String($0.rawValue.dropFirst(7))) }
            return nil
        }
        return s
    }
    func start() { host.start() }
    func containerDidLayout() { host.refreshLayout() }
    func toggle(_ edge: SlotEdge) { host.toggle(edge) }
    func togglePinOfCurrent() { host.togglePinOfCurrent() }
    func cycleBackdropOfCurrent() { host.cycleBackdropOfCurrent() }
    func clearCurrent() { host.clearCurrent() }
    var isPointerOverShownSlot: Bool { host.isPointerOverShownSlot }
    var isPlaylistShown: Bool { edge(showing: Self.playlist).map(host.isShown) ?? false }
    var pages: [PluginPanel] { host.livePages.compactMap { $0.2.view as? PluginPanel } }
    var shownPages: [PluginPanel] { host.shownPages.compactMap { $0.view as? PluginPanel } }
    func page(withToken token: Int) -> PluginPanel? { pages.first { $0.token == token } }
    var pageUnderPointer: PluginPanel? { shownPages.first { $0.hasPointer } }
    func panelInfo(for page: PluginPanel) -> PanelInfo? {
        guard let (edge, id, _) = host.livePages.first(where: { $0.2.view === page }) else { return nil }
        let state = host.configuration(edge), mode = host.effectiveMode(edge)
        return PanelInfo(slot: edge, mode: mode, backdrop: mode == .pinned ? .dark : state.backdrop,
                         shown: host.isShown(edge) && host.activeTab(edge) == id,
                         focused: page.window?.firstResponder.map { responder in
                             guard let view = responder as? NSView else { return false }
                             return view === page || view.isDescendant(of: page)
                         } ?? false)
    }
    private func edge(holding id: SlotTabID) -> SlotEdge? {
        SlotEdge.allCases.first { host.configuration($0).tabs.contains(id) }
    }
    private func edge(showing id: SlotTabID) -> SlotEdge? { SlotEdge.allCases.first { host.activeTab($0) == id } }
    private var firstEmpty: SlotEdge? { [SlotEdge.right, .left, .bottom].first { host.configuration($0).tabs.isEmpty } }
    func togglePlaylist() {
        let id = Self.playlist, edge = edge(holding: Self.playlist) ?? firstEmpty ?? .right
        if host.isShown(edge), host.activeTab(edge) == id { host.hide(edge); return }
        host.add(id, edge: edge); host.show(edge)
    }
    func showPlaylistForFilter() {
        if !isPlaylistShown { togglePlaylist() }
        if isPlaylistShown { playlistView.beginFilter() }
    }
    func togglePlugin(focus: Bool = false) {
        for edge in SlotEdge.allCases {
            let ids = host.configuration(edge).tabs.filter { $0.rawValue.hasPrefix("plugin:") }
            guard let first = ids.first else { continue }
            if host.isShown(edge), !focus, host.activeTab(edge)?.rawValue.hasPrefix("plugin:") == true { host.hide(edge); return }
            if host.activeTab(edge)?.rawValue.hasPrefix("plugin:") != true { host.select(first, edge: edge) }
            host.show(edge, focus: focus); return
        }
        guard let plugin = allPlugins.first else { onMessage?("No plugin page: add plugin=Name | URL to framescrub.conf, or open a link with plugin="); return }
        guard let edge = firstEmpty else { onMessage?("Every slot is taken: choose \(plugin.name) in a slot's + menu"); return }
        host.add(Self.id(plugin.name), edge: edge); host.show(edge, focus: focus)
    }
    @discardableResult func showLinkPage(_ url: URL) -> Bool {
        guard PluginPageSource.link.accepts(url) else { return false }
        for shownOnly in [true, false] {
            for edge in SlotEdge.allCases {
                let ids = shownOnly ? [host.activeTab(edge)].compactMap { $0 } : host.configuration(edge).tabs
                for id in ids {
                    guard id.rawValue.hasPrefix("plugin:") else { continue }
                    host.select(id, edge: edge); host.show(edge)
                    guard let page = host.page(id, edge: edge)?.view as? PluginPanel else { continue }
                    page.load(url, from: .link); return true
                }
            }
        }
        linkPlugin = PluginEntry(name: SlotDefaults.linkPluginName, url: url); registerPlugins()
        let id = Self.id(SlotDefaults.linkPluginName), edge = firstEmpty ?? .right
        let transient = !host.configuration(edge).tabs.contains(id)
        host.add(id, edge: edge, transient: transient); host.show(edge)
        (host.page(id, edge: edge)?.view as? PluginPanel)?.load(url, from: .link)
        return true
    }
    @discardableResult func hideOverlays() -> Bool { host.hideOverlays() }
    func hide(page: PluginPanel) {
        if let (edge, id, _) = host.livePages.first(where: { $0.2.view === page }), host.activeTab(edge) == id { host.hide(edge) }
    }
    func pageChosePlay(_ page: PluginPanel) {
        if let edge = host.livePages.first(where: { $0.2.view === page })?.0 { host.choice(in: edge) }
    }
    func playlistChosePlay() { if let edge = edge(holding: Self.playlist) { host.choice(in: edge) } }
    func escape(in view: NSView) -> Bool { host.escape(in: view) }
    func videoChanged(cause: VideoChangeCause) { host.flash(Self.playlist, cause: cause, enabled: flashEnabled) }

    private var allPlugins: [PluginEntry] {
        guard let linkPlugin, !plugins.contains(where: { $0.name == linkPlugin.name }) else { return plugins }
        return plugins + [linkPlugin]
    }
    func configChanged(_ config: Config) {
        let oldNames = Set(allPlugins.map(\.name))
        plugins = config.plugins; flashEnabled = config.slotFlash
        let newNames = Set(allPlugins.map(\.name))
        for name in oldNames.subtracting(newNames) { host.unregister(Self.id(name)) }
        host.revealBand = CGFloat(config.slotRevealDistance)
        registerPlugins()
        for (edge, id, live) in host.livePages {
            guard let page = live.view as? PluginPanel else { continue }
            let name = String(id.rawValue.dropFirst(7))
            guard let entry = allPlugins.first(where: { $0.name == name }) else { host.invalidatePage(id, edge: edge); continue }
            if entryURLs[ObjectIdentifier(page)] != entry.url {
                entryURLs[ObjectIdentifier(page)] = entry.url
                page.load(entry.url, from: entry == linkPlugin ? .link : .settings)
            }
        }
        host.refreshContents()
    }
    private func registerPlugins() {
        for entry in allPlugins {
            host.register(SlotTabDescriptor(id: Self.id(entry.name), title: entry.name) { [weak self] _ in
                guard let self, let current = allPlugins.first(where: { $0.name == entry.name }) else { return nil }
                let panel = PluginPanel(); configurePage?(panel)
                panel.load(current.url, from: current == linkPlugin ? .link : .settings)
                entryURLs[ObjectIdentifier(panel)] = current.url
                let page = SlotPage(view: panel, visibilityChanged: { [weak panel] in panel?.isShownInSlot = $0 }, dropped: { [weak self, weak panel] in
                    guard let panel else { return }; self?.entryURLs[ObjectIdentifier(panel)] = nil; self?.onPageDropped?(panel)
                })
                page.focus = { [weak panel] in panel?.focus() }
                page.isTyping = { [weak panel] in panel?.isTyping ?? false }
                page.reload = { [weak panel] in panel?.reload() }
                page.drawsOwnTextShadow = true
                return page
            })
        }
    }
    private func registerPlaylist() {
        host.register(SlotTabDescriptor(id: Self.playlist, title: "Playlist", symbol: "play.rectangle", singleton: true) { [weak self] _ in
            guard let self else { return nil }
            let page = SlotPage(view: playlistView)
            page.tools = { [weak self] in self?.playlistView.tools ?? [] }
            page.focus = { [weak self] in self?.playlistView.beginFilter() }
            page.isTyping = { [weak self] in self?.playlistView.isEditingFilter ?? false }
            page.filterEdited = { [weak self] in self?.playlistView.filterEdited($0) }
            page.filterCommand = { [weak self] in self?.playlistView.filterCommand($0) ?? false }
            page.filterClosed = { [weak self] in self?.playlistView.filterClosed() }
            page.filterEnded = { [weak self] in self?.playlistView.filterEnded() }
            return page
        })
        playlistView.onBeginFilter = { [weak self] in
            guard let self else { return }
            if !isPlaylistShown { togglePlaylist() }
            guard let edge = edge(showing: Self.playlist), host.isShown(edge), let capsule = host.capsule(edge) else { return }
            capsule.setVisible(true, animated: false)
            capsule.beginFilter(text: playlistView.filterText)
        }
        playlistView.onToolsChanged = { [weak self] in self?.host.refreshContents() }
        playlistView.editingFilter = { [weak self] in
            guard let self, let edge = edge(showing: Self.playlist) else { return false }
            return host.capsule(edge)?.isEditingFilter ?? false
        }
    }
}
