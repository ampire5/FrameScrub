import AppKit
import FrameScrubCore
import HomeScreenKit
import HomeScreenModel

/// Home's source (Home spec, Source): Recent's video cards and Stash's page; no places or folders yet. Recent is read
/// afresh on each listing, dimmed once its shares answer; clicks and menus go back to the window.
@MainActor final class FrameScrubHomeSource: HomeSource {
    weak var view: HomeBrowserView?
    /// A Recent card opened (any click: one window).
    var onOpen: ((URL) -> Void)?
    /// A Recent card's menu item: `finder`, `copy`, `remove`.
    var onMenu: ((URL, String) -> Void)?

    private let recentURLs: () -> [URL]
    private let thumbnails: ThumbnailStore
    private let thumbnailer: RecentThumbnailer
    private let stashPage: () -> NSView?
    private let hasStash: () -> Bool
    /// Lengths the thumbnailer found for files the position store has none for, by path, for this run.
    private var durations: [String: Double] = [:]
    private var sorts: [String: BrowserSort] = [:]
    private var pictures: Task<Void, Never>?
    /// The files given to the thumbnailer and not done: a new ask that holds no others leaves it running (a start
    /// cancels the file being made).
    private var pending: [URL] = []

    init(recentURLs: @escaping () -> [URL], thumbnails: ThumbnailStore, thumbnailer: RecentThumbnailer,
         stashPage: @escaping () -> NSView?, hasStash: @escaping () -> Bool) {
        self.recentURLs = recentURLs
        self.thumbnails = thumbnails
        self.thumbnailer = thumbnailer
        self.stashPage = stashPage
        self.hasStash = hasStash
    }

    func places() async -> [BrowserEntry] { [] }

    /// Recent at once from the stores, then again with the files whose share does not answer in a second dimmed
    /// (only when there are any); the Stash page lists nothing.
    func list(_ location: BrowserLocation) -> AsyncThrowingStream<BrowserListing, Error> {
        guard case .source(HomeRecent.source) = location else { return AsyncThrowingStream { $0.finish() } }
        let urls = recentURLs()
        let resume = ResumeStore()
        let entries = { [durations] (dimmed: Set<String>) in
            HomeRecent.entries(urls, resume: { resume.entry(for: $0) }, durations: durations, dimmed: dimmed)
        }
        return AsyncThrowingStream { continuation in
            continuation.yield(BrowserListing(entries: entries([]), complete: true))
            let task = Task { @MainActor in
                let reachable = await PathAvailability.check(urls.map(\.path), timeout: .seconds(1))
                let gone = Set(urls.map(\.path).filter { reachable[$0] == .some(false) })
                if !gone.isEmpty, !Task.isCancelled {
                    continuation.yield(BrowserListing(entries: entries(gone), complete: true))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func folders(in folder: URL) async throws -> [BrowserEntry] { [] }
    func parent(of folder: URL) -> BrowserLocation { .source(HomeRecent.source) }
    func symbol(for entry: BrowserEntry) -> String { "film" }

    /// The saved pictures, read off the main thread in the order asked (those in view first); the files without one
    /// get their keyframe from the thumbnailer (one at a time, in the background), and the card its length.
    func wantImages(_ ids: [String], width: CGFloat) {
        let urls = ids.compactMap(HomeRecent.path(ofID:)).map { URL(filePath: $0, directoryHint: .notDirectory) }
        pictures?.cancel()
        let thumbnails = thumbnails
        pictures = Task { @MainActor [weak self] in
            var missing: [URL] = []
            for url in urls {
                let image = await Task.detached(priority: .utility) { thumbnails.image(for: url) }.value
                guard let self, !Task.isCancelled else { return }
                if let image { self.view?.setImage(image, for: "recent:" + url.path) } else { missing.append(url) }
            }
            guard let self, !Task.isCancelled else { return }
            let new = missing.filter { !self.pending.contains($0) }
            guard !new.isEmpty else { return }
            self.pending += new
            let resume = ResumeStore()
            let jobs = self.pending.map {
                RecentThumbnailer.Job(url: $0, seconds: resume.entry(for: $0).flatMap { $0.position > 0 ? $0.position : nil })
            }
            self.thumbnailer.start(jobs) { [weak self] url, duration in
                MainActor.assumeIsolated { self?.thumbnailMade(url, duration: duration) }
            }
        }
    }

    /// Home left Recent: no more pictures for it.
    func stopImages() {
        pictures?.cancel()
        pictures = nil
        pending = []
        thumbnailer.cancel()
    }

    private func thumbnailMade(_ url: URL, duration: Double) {
        pending.removeAll { $0 == url }
        let known = durations[url.path] != nil
        durations[url.path] = duration
        let thumbnails = thumbnails
        Task { @MainActor [weak self] in
            let image = await Task.detached(priority: .utility) { thumbnails.image(for: url) }.value
            if let image { self?.view?.setImage(image, for: "recent:" + url.path) }
        }
        // The card's length line: Recent is listed again (cheap: from the stores) when a length is new.
        if !known, ResumeStore().entry(for: url)?.duration == nil, view?.location == .source(HomeRecent.source) {
            view?.reload()
        }
    }

    func menu(for entry: BrowserEntry, in location: BrowserLocation) -> [HomeMenuItem] {
        [HomeMenuItem(id: "finder", title: "Show in Finder"), HomeMenuItem(id: "copy", title: "Copy Path"),
         HomeMenuItem(id: "remove", title: "Remove from Recent")]
    }

    func perform(_ item: String, on entry: BrowserEntry, in location: BrowserLocation) { onMenu?(entry.url, item) }

    func open(_ entry: BrowserEntry, in location: BrowserLocation, sort: BrowserSort, how: HomeClick) {
        onOpen?(entry.url)
    }

    func rename(_ entry: BrowserEntry, to name: String) async throws -> BrowserEntry {
        throw CocoaError(.featureUnsupported)   // Recent's cards cannot be renamed (`canRename` is false)
    }

    func trash(_ entry: BrowserEntry) async throws { throw CocoaError(.featureUnsupported) }

    func sort(for location: BrowserLocation) -> BrowserSort {
        guard case .source(let id) = location else { return .standard }
        return sorts[id] ?? BrowserSort(key: .date, ascending: false)
    }

    func setSort(_ sort: BrowserSort, for location: BrowserLocation) {
        if case .source(let id) = location { sorts[id] = sort }
    }

    func info(for source: String) -> HomeSourceInfo {
        source == HomeRecent.stash
            ? HomeSourceInfo(title: "Stash", page: stashPage())
            : HomeSourceInfo(title: "Recent", sortKeys: [.date, .name], groupsByDate: true, noun: "video",
                             emptyHint: "Drop a video here or press ⌘O")
    }

    /// Recent; Stash's library when `stash-url` is set.
    func sidebar() async -> [HomeSidebarSection] {
        var sections = [HomeSidebarSection(id: "library", title: nil, rows: [
            HomeSidebarRow(id: HomeRecent.source, title: "Recent", symbol: "clock", location: .source(HomeRecent.source)),
        ])]
        if hasStash() {
            sections.append(HomeSidebarSection(id: "stash", title: "Stash", rows: [
                HomeSidebarRow(id: HomeRecent.stash, title: "Library", symbol: "server.rack", location: .source(HomeRecent.stash)),
            ]))
        }
        return sections
    }

    func pageFilterChosen(_ index: Int, in source: String) {}

    func moved(from old: BrowserLocation?, to new: BrowserLocation) {
        if old == .source(HomeRecent.source), new != old { stopImages() }
    }
}
