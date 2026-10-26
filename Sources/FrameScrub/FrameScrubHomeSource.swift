import AppKit
import FrameScrubCore
import HomeScreenKit
import HomeScreenModel

/// Home's source (Home spec, Source): Recent's video cards, the places and folders, and Stash's page. Recent is read
/// afresh on each listing, dimmed once its shares answer; a folder is read off the main thread, its last listing shown
/// at once on the way back. Clicks and menus go back to the window.
@MainActor final class FrameScrubHomeSource: HomeSource {
    weak var view: HomeBrowserView?
    /// A video card opened (any click: one window), from Recent or from a folder, with the sort it was shown in.
    var onOpen: ((URL, BrowserLocation, BrowserSort) -> Void)?
    /// A card's menu item: `finder`, `copy`, and Recent's `remove`.
    var onMenu: ((URL, String) -> Void)?

    private let recentURLs: () -> [URL]
    private let stashPage: () -> NSView?
    private let hasStash: () -> Bool
    /// Recent's pictures: the last frame seen in each file (`ThumbnailStore`), a keyframe where it was left for those
    /// without one. A folder's: a keyframe near a tenth of each video, kept apart (`posters`, more of them, smaller).
    private let recentPictures: PictureQueue
    private let folderPictures: PictureQueue
    /// Lengths found while making pictures for files the position store has none for, by path; kept across runs.
    private var durations: [String: Double] = [:]
    private let durationStore = DurationStore()
    private var durationSave: DispatchWorkItem?
    private var sorts: [BrowserLocation: BrowserSort] = [:]
    /// Each folder's last listing as read, for the way back and for re-listing with new lengths without a read.
    private var listings: [URL: [BrowserEntry]] = [:]
    /// Set while a folder is listed again only for its cards' lengths: the kept listing, no read.
    private var relistOnly = false
    private var relist: DispatchWorkItem?

    init(recentURLs: @escaping () -> [URL], thumbnails: ThumbnailStore, thumbnailer: RecentThumbnailer,
         stashPage: @escaping () -> NSView?, hasStash: @escaping () -> Bool) {
        self.recentURLs = recentURLs
        self.stashPage = stashPage
        self.hasStash = hasStash
        recentPictures = PictureQueue(store: thumbnails, thumbnailer: thumbnailer, prefix: "recent:", atPosition: true)
        // A folder of a few hundred videos: ~40 KB each at 480 px; the newest 2 000 are kept.
        let posters = ThumbnailStore(directory: ThumbnailStore.defaultDirectory.appendingPathComponent("posters"),
                                     limit: 2000, maxSide: 480)
        folderPictures = PictureQueue(store: posters, thumbnailer: RecentThumbnailer(store: posters), prefix: "",
                                      atPosition: false)
        let store = durationStore
        Task { @MainActor [weak self] in   // the file is read off the main thread, once
            let kept = await Task.detached(priority: .utility) { store.all() }.value
            guard let self, !kept.isEmpty else { return }
            self.durations.merge(kept) { now, _ in now }
            if case .folder? = self.view?.location {   // a folder shown before they came: its cards get them
                self.relistOnly = true
                self.view?.reload()
            }
        }
        for queue in [recentPictures, folderPictures] {
            queue.onPicture = { [weak self] id, image in self?.view?.setImage(image, for: id) }
            queue.onDuration = { [weak self] url, duration in self?.lengthFound(url, duration) }
        }
    }

    // MARK: Places and folders

    private var placeURLs: [URL] {
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil,
                                                            options: .skipHiddenVolumes) ?? []
        return HomeFolders.places(home: FileManager.default.homeDirectoryForCurrentUser, volumes: volumes).map(\.url)
    }

    func places() async -> [BrowserEntry] {
        let volumes = await Task.detached(priority: .userInitiated) {
            FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: .skipHiddenVolumes) ?? []
        }.value
        return HomeFolders.places(home: FileManager.default.homeDirectoryForCurrentUser, volumes: volumes)
    }

    func list(_ location: BrowserLocation) -> AsyncThrowingStream<BrowserListing, Error> {
        switch location {
        case .source(HomeRecent.source): return listRecent()
        case .source: return AsyncThrowingStream { $0.finish() }
        case .places:
            return AsyncThrowingStream { continuation in
                let task = Task { @MainActor [weak self] in
                    continuation.yield(BrowserListing(entries: await self?.places() ?? [], complete: true))
                    continuation.finish()
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        case .folder(let folder): return listFolder(folder)
        }
    }

    /// The kept listing at once (marked provisional), then the folder as read now, off the main thread; with
    /// `relistOnly`, the kept one alone with the lengths found since.
    private func listFolder(_ folder: URL) -> AsyncThrowingStream<BrowserListing, Error> {
        let kept = listings[folder]
        let onlyKept = relistOnly && kept != nil
        relistOnly = false
        return AsyncThrowingStream { continuation in
            if let kept {
                var listing = BrowserListing(entries: self.withFacts(kept), complete: onlyKept)
                listing.isProvisional = !onlyKept
                continuation.yield(listing)
                if onlyKept { continuation.finish(); return }
            }
            let task = Task { @MainActor [weak self] in
                do {
                    let entries = try await Task.detached(priority: .userInitiated) {
                        try HomeFolders.entries(in: folder)
                    }.value
                    guard let self, !Task.isCancelled else { return }
                    self.listings[folder] = entries
                    continuation.yield(BrowserListing(entries: self.withFacts(entries), complete: true))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func withFacts(_ entries: [BrowserEntry]) -> [BrowserEntry] {
        let resume = ResumeStore()
        return HomeFolders.withFacts(entries, resume: { resume.entry(for: $0) }, durations: durations)
    }

    func lastListing(for location: BrowserLocation) -> BrowserListing? {
        guard case .folder(let folder) = location, let kept = listings[folder] else { return nil }
        return BrowserListing(entries: withFacts(kept), complete: true)
    }

    func folders(in folder: URL) async throws -> [BrowserEntry] {
        try await Task.detached(priority: .userInitiated) { try HomeFolders.entries(in: folder) }.value
            .filter(\.isContainer)
    }

    func parent(of folder: URL) -> BrowserLocation { HomeFolders.parent(of: folder, places: placeURLs) }

    func symbol(for entry: BrowserEntry) -> String {
        switch entry.kind {
        case .place:   // the home folder, else a volume (shares are not always under /Volumes)
            entry.url.standardizedFileURL == FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
                ? "house" : "externaldrive"
        case .folder, .archive: "folder"
        case .file, .collection: "film"
        }
    }

    // MARK: Pictures

    /// The cards' pictures, those in view first: saved ones read off the main thread, the others made in the
    /// background one at a time.
    func wantImages(_ ids: [String], width: CGFloat) {
        if view?.location == .source(HomeRecent.source) {
            recentPictures.want(ids)
        } else {
            folderPictures.want(ids.filter { !$0.contains(":") || $0.hasPrefix("/") })
        }
    }

    /// Home hidden or left a place: no more pictures for it.
    func stopImages() {
        recentPictures.stop()
        folderPictures.stop()
    }

    /// A length is new: the cards that show it are listed again from what is kept (no read), once for a burst.
    private func lengthFound(_ url: URL, _ duration: Double) {
        guard durations[url.path] == nil else { return }
        durations[url.path] = duration
        durationStore.set(duration, for: url.path)
        durationSave?.cancel()
        let store = durationStore
        let save = DispatchWorkItem { store.save() }
        durationSave = save
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2, execute: save)   // once for a burst
        guard ResumeStore().entry(for: url)?.duration == nil else { return }
        relist?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let view = self.view else { return }
            if case .folder = view.location { self.relistOnly = true }
            view.reload()
        }
        relist = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    // MARK: Cards

    func menu(for entry: BrowserEntry, in location: BrowserLocation) -> [HomeMenuItem] {
        var items = [HomeMenuItem(id: "finder", title: "Show in Finder"), HomeMenuItem(id: "copy", title: "Copy Path")]
        if location == .source(HomeRecent.source) { items.append(HomeMenuItem(id: "remove", title: "Remove from Recent")) }
        return items
    }

    func perform(_ item: String, on entry: BrowserEntry, in location: BrowserLocation) { onMenu?(entry.url, item) }

    func open(_ entry: BrowserEntry, in location: BrowserLocation, sort: BrowserSort, how: HomeClick) {
        guard entry.isFile else { return }
        onOpen?(entry.url, location, sort)
    }

    func rename(_ entry: BrowserEntry, to name: String) async throws -> BrowserEntry {
        let target = entry.url.deletingLastPathComponent().appendingPathComponent(name)
        try await Task.detached(priority: .userInitiated) { try FileManager.default.moveItem(at: entry.url, to: target) }.value
        listings[entry.url.deletingLastPathComponent()] = nil
        var renamed = entry
        renamed.url = target
        renamed.name = name
        return renamed
    }

    /// To the Trash; a volume without one (a share) refuses, and the browser says so.
    func trash(_ entry: BrowserEntry) async throws {
        try await Task.detached(priority: .userInitiated) {
            try FileManager.default.trashItem(at: entry.url, resultingItemURL: nil)
        }.value
        listings[entry.url.deletingLastPathComponent()] = nil
    }

    /// Recent: newest first; a folder: by name, or as the user last sorted it this run.
    func sort(for location: BrowserLocation) -> BrowserSort {
        sorts[location] ?? (location == .source(HomeRecent.source) ? BrowserSort(key: .date, ascending: false) : .standard)
    }

    func setSort(_ sort: BrowserSort, for location: BrowserLocation) { sorts[location] = sort }

    func info(for source: String) -> HomeSourceInfo {
        source == HomeRecent.stash
            ? HomeSourceInfo(title: "Stash", page: stashPage())
            : HomeSourceInfo(title: "Recent", sortKeys: [.date, .name], groupsByDate: true, noun: "video",
                             emptyHint: "Drop a video here or press ⌘O")
    }

    /// Recent; the places, each opening as a tree; Stash's library when `stash-url` is set.
    func sidebar() async -> [HomeSidebarSection] {
        let places = await places().map {
            HomeSidebarRow(id: $0.id, title: $0.name, symbol: symbol(for: $0), location: .folder($0.url), expandable: true)
        }
        var sections = [
            HomeSidebarSection(id: "library", title: nil, rows: [
                HomeSidebarRow(id: HomeRecent.source, title: "Recent", symbol: "clock", location: .source(HomeRecent.source)),
            ]),
            HomeSidebarSection(id: "places", title: "Places", rows: places),
        ]
        if hasStash() {
            sections.append(HomeSidebarSection(id: "stash", title: "Stash", rows: [
                HomeSidebarRow(id: HomeRecent.stash, title: "Library", symbol: "server.rack", location: .source(HomeRecent.stash)),
            ]))
        }
        return sections
    }

    func pageFilterChosen(_ index: Int, in source: String) {}

    func moved(from old: BrowserLocation?, to new: BrowserLocation) {
        if old != new { stopImages() }
    }

    // MARK: Recent

    /// Recent at once from the stores, then again with the files whose share does not answer in a second dimmed
    /// (only when there are any).
    private func listRecent() -> AsyncThrowingStream<BrowserListing, Error> {
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
}

/// One kind of card picture: saved ones read off the main thread in the order asked, the missing ones made by a
/// thumbnailer (one file at a time, `.utility`), whose run is left going when an ask brings nothing new (a new start
/// would cancel the file being made). Card ids are `prefix` + the file's path.
@MainActor private final class PictureQueue {
    var onPicture: ((String, CGImage) -> Void)?
    var onDuration: ((URL, Double) -> Void)?

    private let store: ThumbnailStore
    private let thumbnailer: RecentThumbnailer
    private let prefix: String
    /// Recent's keyframe is where the file was left; a folder's, a tenth in.
    private let atPosition: Bool
    private var reading: Task<Void, Never>?
    private var pending: [URL] = []

    init(store: ThumbnailStore, thumbnailer: RecentThumbnailer, prefix: String, atPosition: Bool) {
        self.store = store
        self.thumbnailer = thumbnailer
        self.prefix = prefix
        self.atPosition = atPosition
    }

    func want(_ ids: [String]) {
        let urls = ids.filter { $0.hasPrefix(prefix) }
            .map { URL(filePath: String($0.dropFirst(prefix.count)), directoryHint: .notDirectory) }
            .filter { Playlist.videoExtensions.contains($0.pathExtension.lowercased()) }
        reading?.cancel()
        let store = store, prefix = prefix
        reading = Task { @MainActor [weak self] in
            var missing: [URL] = []
            for url in urls {
                let image = await Task.detached(priority: .utility) { store.image(for: url) }.value
                guard let self, !Task.isCancelled else { return }
                if let image { self.onPicture?(prefix + url.path, image) } else { missing.append(url) }
            }
            guard let self, !Task.isCancelled else { return }
            let new = missing.filter { !self.pending.contains($0) }
            guard !new.isEmpty else { return }
            self.pending += new
            let resume = self.atPosition ? ResumeStore() : nil
            let jobs = self.pending.map {
                RecentThumbnailer.Job(url: $0, seconds: resume?.entry(for: $0).flatMap { $0.position > 0 ? $0.position : nil })
            }
            self.thumbnailer.start(jobs) { [weak self] url, duration in
                MainActor.assumeIsolated { self?.made(url, duration: duration) }
            }
        }
    }

    func stop() {
        reading?.cancel()
        reading = nil
        pending = []
        thumbnailer.cancel()
    }

    private func made(_ url: URL, duration: Double) {
        pending.removeAll { $0 == url }
        onDuration?(url, duration)
        let store = store, id = prefix + url.path
        Task { @MainActor [weak self] in
            let image = await Task.detached(priority: .utility) { store.image(for: url) }.value
            if let image { self?.onPicture?(id, image) }
        }
    }
}
