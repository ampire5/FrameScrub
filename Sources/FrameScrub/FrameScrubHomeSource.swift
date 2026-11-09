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
    private let unreadable: UnreadableFiles
    private let folderMonitor = FolderChangeMonitor()
    private var watchingVisible = true
    private var thumbnailsPaused = false
    /// Recent's pictures: the last frame seen in each file (`ThumbnailStore`), a keyframe where it was left for those
    /// without one. A folder's: a keyframe near a tenth of each video, kept apart (`posters`, more of them, smaller).
    private let recentPictures: PictureQueue
    private let folderPictures: PictureQueue
    /// Facts (size, codec, rate, length) found while making pictures, by path; kept across runs (`FileFactsStore`).
    private var facts: [String: FileFacts] = [:]
    private var positions: [String: ResumeEntry] = [:]
    private let factsStore = FileFactsStore.shared
    private var metadataInspector: MediaMetadataInspector?
    /// The sorts of Recent and the app's lists, for this run; a folder's are kept (`folderSorts`).
    private var sorts: [BrowserLocation: BrowserSort] = [:]
    private let folderSorts: FolderSorts
    /// `playlist-sort`'s order, for a folder without one of its own.
    private let defaultSort: () -> BrowserSort
    /// Each folder's last listing as read, for the way back and for re-listing with new lengths without a read.
    private var listings: [URL: [BrowserEntry]] = [:]
    /// Folder cards' facts and the videos their covers are made of, by folder, for this run; the run filling them.
    private var folderFacts: [URL: (summary: CardSummary, cover: [URL])] = [:]
    private var factsTask: Task<Void, Never>?
    private var folderCardIDs: [String] = []
    /// A video whose poster is being made for a folder's cover, and that folder card's id.
    private var coverFor: [String: (id: String, folder: URL)] = [:]
    private typealias ListingContinuation = AsyncThrowingStream<BrowserListing, Error>.Continuation
    /// Metadata updates go through the existing subscription, keeping the grid, pictures and scroll alive.
    private var activeListing: (id: UUID, location: BrowserLocation, continuation: ListingContinuation, flag: CancellationFlag, needsPictures: Bool)?
    private var recentDimmed: Set<String> = []
    private var relist: DispatchWorkItem?

    private func keepListing(_ continuation: ListingContinuation, at location: BrowserLocation) -> UUID {
        let old = activeListing
        let id = UUID()
        activeListing = (id, location, continuation, CancellationFlag(), true)
        folderMonitor.stop()
        old?.flag.cancel()
        old?.continuation.finish()
        return id
    }

    private func endListing(_ id: UUID) {
        if activeListing?.id == id {
            activeListing?.flag.cancel()
            activeListing = nil
            folderMonitor.stop()
        }
    }

    init(folderSorts: FolderSorts, defaultSort: @escaping () -> BrowserSort, recentURLs: @escaping () -> [URL],
         thumbnails: ThumbnailStore, thumbnailer: RecentThumbnailer, stashPage: @escaping () -> NSView?,
         hasStash: @escaping () -> Bool, unreadable: UnreadableFiles? = nil) {
        self.folderSorts = folderSorts
        self.defaultSort = defaultSort
        self.recentURLs = recentURLs
        self.stashPage = stashPage
        self.hasStash = hasStash
        self.unreadable = unreadable ?? UnreadableFiles()
        recentPictures = PictureQueue(store: thumbnails, thumbnailer: thumbnailer, prefix: "recent:", atPosition: true)
        // A folder of a few hundred videos: ~40 KB each at 480 px; the newest 2 000 are kept.
        let posters = ThumbnailStore(directory: ThumbnailStore.defaultDirectory.appendingPathComponent("posters"),
                                     limit: 2000, maxSide: ThumbnailStore.configuredSide(poster: true))
        folderPictures = PictureQueue(store: posters, thumbnailer: RecentThumbnailer(store: posters), prefix: "",
                                      atPosition: false)
        folderPictures.onMade = { [weak self] url in self?.coverPosterMade(url) }
        folderPictures.onHave = { [weak self] url in self?.posterIn(url) }
        for queue in [recentPictures, folderPictures] {
            queue.onPicture = { [weak self] id, image in self?.view?.setImage(image, for: id) }
            queue.onFacts = { [weak self] url, facts in self?.factsFound(url, facts) }
            queue.onFailure = { [weak self] url, failure in self?.pictureFailed(url, failure) }
            queue.hasFacts = { [weak self] url in self?.facts[url.path] != nil }
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

    /// The kept listing at once (marked provisional), then the folder as read now, off the main thread.
    /// The stream stays open for metadata updates until the browser leaves or explicitly reloads it.
    private func listFolder(_ folder: URL) -> AsyncThrowingStream<BrowserListing, Error> {
        let kept = listings[folder]
        return AsyncThrowingStream { continuation in
            let id = self.keepListing(continuation, at: .folder(folder))
            if let kept {
                var listing = BrowserListing(entries: self.withFacts(kept), complete: false)
                listing.isProvisional = true
                continuation.yield(listing)
            }
            self.watchFolder(folder, id: id)
            self.readFolder(folder, id: id)
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.endListing(id) }
            }
        }
    }

    private struct FolderRead: Sendable {
        let folder: URL
        let id: UUID
        let flag: CancellationFlag
    }

    /// A stalled SMB listing holds one utility worker; rapid changes/navigation replace its one pending request.
    private lazy var folderReader = LatestOnlyWorker<FolderRead>(label: "framescrub.home-listing", qos: .utility) { [weak self] request in
        guard !request.flag.isCancelled else { return }
        do {
            let entries = try HomeFolders.entries(in: request.folder)
            guard !request.flag.isCancelled else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.folderEntries(entries, request: request) }
            }
            let urls = entries.filter(\.isFile).map(\.url)
            let resume = ResumeStore()
            let positions = Dictionary(entries.filter(\.isFile).compactMap { entry -> (String, ResumeEntry)? in
                guard let size = entry.size, let saved = resume.entry(for: entry.url, size: size) else { return nil }
                return (entry.url.path, saved)
            }, uniquingKeysWith: { a, _ in a })
            let facts = FileFactsStore.shared.facts(for: urls)
            guard !request.flag.isCancelled else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.folderMetadata(facts, positions: positions, entries: entries, request: request) }
            }
        } catch {
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.activeListing?.id == request.id else { return }
                    self.activeListing?.continuation.finish(throwing: error)
                }
            }
        }
    }

    private func readFolder(_ folder: URL, id: UUID) {
        guard let active = activeListing, active.id == id else { return }
        folderReader.submit(FolderRead(folder: folder, id: id, flag: active.flag))
    }

    private func watchFolder(_ folder: URL, id: UUID) {
        guard watchingVisible else { return }
        folderMonitor.watch(folder) { [weak self] in
            MainActor.assumeIsolated { self?.readFolder(folder, id: id) }
        }
    }

    private func folderEntries(_ entries: [BrowserEntry], request: FolderRead) {
        guard activeListing?.id == request.id, !request.flag.isCancelled else { return }
        let first = activeListing?.needsPictures == true
        activeListing?.needsPictures = false
        let old = Dictionary((listings[request.folder] ?? []).map { ($0.url, $0) }, uniquingKeysWith: { a, _ in a })
        listings[request.folder] = entries
        folderFacts[request.folder] = nil
        folderVideos = withFacts(entries).filter(\.isFile).map(\.url)
        let current = Set(folderVideos)
        let retries = folderPictures.retryFailures().intersection(current)
        let changed = entries.filter { entry in
            entry.isFile && current.contains(entry.url) && (old[entry.url]?.date != entry.date || old[entry.url]?.size != entry.size)
        }.map(\.url)
        let wanted = Set(changed).union(retries)
        for url in wanted { havePosters.remove(url.path) }
        activeListing?.continuation.yield(BrowserListing(entries: withFacts(entries), complete: true))
        if progressFolder == request.folder, !thumbnailsPaused {
            if first {
                folderPictures.want(inViewVideos.filter { current.contains($0) }.map(\.path), rest: folderVideos)
                wantFolderCards(folderCardIDs, in: request.folder)
            } else if !wanted.isEmpty {
                folderPictures.want(folderVideos.filter { wanted.contains($0) }.map(\.path))
            }
        }
        showProgress()
    }

    private func folderMetadata(_ loaded: [String: FileFacts], positions saved: [String: ResumeEntry],
                                entries: [BrowserEntry], request: FolderRead) {
        guard activeListing?.id == request.id, !request.flag.isCancelled else { return }
        for entry in entries where entry.isFile {
            facts[entry.url.path] = loaded[entry.url.path]
            positions[entry.url.path] = saved[entry.url.path]
        }
        view?.setFacts(loaded)
        view?.setLastViewed(Dictionary(saved.compactMap { path, entry in
            entry.lastViewedAt.map { (URL(fileURLWithPath: path), $0) }
        }, uniquingKeysWith: { a, _ in a }))
        activeListing?.continuation.yield(BrowserListing(entries: withFacts(entries), complete: true))
    }

    /// Explicit refresh and filesystem events use the same subscription: no empty grid or lost pictures.
    func refresh() {
        recentPictures.retryFailures()
        if let active = activeListing, case .folder(let folder) = active.location {
            readFolder(folder, id: active.id)
        } else {
            view?.reload()
        }
    }

    func setWatchingVisible(_ visible: Bool) {
        guard watchingVisible != visible else { return }
        watchingVisible = visible
        if visible, let active = activeListing, case .folder(let folder) = active.location {
            watchFolder(folder, id: active.id) // initial callback reconciles changes missed while invisible
        } else {
            folderMonitor.stop()
        }
    }

    private func withFacts(_ entries: [BrowserEntry]) -> [BrowserEntry] {
        return HomeFolders.withFacts(entries.filter { !unreadable.contains($0) }, resume: { positions[$0.path] }, facts: facts)
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
            guard case .folder(let folder)? = view?.location else { return }
            let videos = withFacts(listings[folder] ?? []).filter(\.isFile).map(\.url)
            let inView = ids.filter { $0.hasPrefix("/") }.map { URL(filePath: $0, directoryHint: .notDirectory) }
                .filter { Playlist.videoExtensions.contains($0.pathExtension.lowercased()) }
            if progressFolder != folder {
                progressFolder = folder
                havePosters = []
            }
            folderVideos = videos
            inViewVideos = inView
            folderPictures.want(ids.filter { $0.hasPrefix("/") }, rest: thumbnailsPaused ? [] : videos,
                                allowGeneration: !thumbnailsPaused)
            wantFolderCards(ids, in: folder)
            showProgress()
        }
    }

    // MARK: Progress (the toolbar's pill: "Posters 120 / 480")

    private var progressFolder: URL?
    private var folderVideos: [URL] = []
    private var inViewVideos: [URL] = []
    private var havePosters: Set<String> = []

    private func posterIn(_ url: URL) {
        guard havePosters.insert(url.path).inserted else { return }
        showProgress()
    }

    /// The folder's posters: those in view first, then the rest; the pill lights only after a second of work.
    private func showProgress(paused suppliedPause: Bool? = nil) {
        let paused = suppliedPause ?? thumbnailsPaused
        guard let view else { return }
        guard !folderVideos.isEmpty else { view.setProgress(nil, delay: .zero); return }
        let current = Set(folderVideos)
        let visible = inViewVideos.filter { current.contains($0) }
        let done = folderVideos.filter { havePosters.contains($0.path) }.count
        let inViewDone = visible.filter { havePosters.contains($0.path) }.count
        let total = folderVideos.count
        let state = ThumbsProgressState(
            fraction: Double(done) / Double(total),
            text: paused ? "Paused · \(done) / \(total)" : "Posters \(done) / \(total)", paused: paused,
            rows: [.init(title: "In view", done: inViewDone, total: visible.count),
                   .init(title: "Rest of folder", done: done - inViewDone, total: total - visible.count)],
            pauseNote: paused ? "Paused" : nil, pausedByUser: paused, working: done < total)
        view.setProgress(state, delay: .seconds(1))
    }

    /// The pill's Pause / Resume: the folder's posters stop, or are asked for again.
    func pauseThumbs(_ on: Bool, in location: BrowserLocation) {
        thumbnailsPaused = on
        if on {
            folderPictures.stop()
            factsTask?.cancel()
            factsTask = nil
            view?.stopWaiting(for: Array(coverFor.values.map(\.id)))
            coverFor = [:]
            showProgress(paused: true)
        } else {
            folderPictures.want(inViewVideos.map(\.path), rest: folderVideos)
            if case .folder(let folder) = location {
                view?.resumeWaiting(for: folderCardIDs)
                wantFolderCards(folderCardIDs, in: folder)
            }
            showProgress()
        }
    }

    /// Home hidden: stop its subscription too, so returning re-reads files and saved playback progress.
    /// A location change has already subscribed to the new place before `moved` arrives: keep that subscription.
    func stopImages(keepingListing: Bool = false) {
        if !keepingListing {
            let listing = activeListing
            activeListing = nil
            listing?.flag.cancel()
            listing?.continuation.finish()
            folderMonitor.stop()
        }
        relist?.cancel()
        relist = nil
        recentPictures.stop()
        folderPictures.stop()
        factsTask?.cancel()
        factsTask = nil
        coverFor = [:]
    }

    /// The folder cards among `ids`, in that order (those in view first): each folder's own listing read off the main
    /// thread one at a time, its facts on the card, then its cover from posters already made; a folder whose videos
    /// have none yet shows its symbol, and its first video's poster is queued (the cover follows when it is in).
    private func wantFolderCards(_ ids: [String], in folder: URL) {
        guard let entries = listings[folder] else { return }
        let byID = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let folders = ids.compactMap { byID[$0] }.filter { $0.kind == .folder }
        folderCardIDs = folders.map(\.id)
        factsTask?.cancel()
        factsTask = Task { @MainActor [weak self] in
            for entry in folders {
                guard let self, !Task.isCancelled else { return }
                if self.folderFacts[entry.url] == nil {
                    let url = entry.url
                    let read = await Task.detached(priority: .utility) { () -> (CardSummary, [URL])? in
                        guard let entries = try? HomeFolders.entries(in: url) else { return nil }
                        let store = ResumeStore()
                        let positions = Dictionary(entries.filter(\.isFile).compactMap { item -> (URL, ResumeEntry)? in
                            guard let size = item.size, let saved = store.entry(for: item.url, size: size) else { return nil }
                            return (item.url, saved)
                        }, uniquingKeysWith: { a, _ in a })
                        return (HomeFolders.summary(of: entries, resume: { positions[$0] }), HomeFolders.coverVideos(entries))
                    }.value
                    guard !Task.isCancelled else { return }
                    guard let read else {
                        self.view?.setSummary(CardSummary(problem: .broken), for: entry.id)
                        continue
                    }
                    self.folderFacts[url] = (read.0, read.1)
                }
                guard let facts = self.folderFacts[entry.url] else { continue }
                self.view?.setSummary(facts.summary, for: entry.id)
                await self.makeCover(entry.id, folder: entry.url, from: facts.cover)
            }
        }
    }

    /// The cover from the posters there are (two by two, as Loupe's folders); none yet: the symbol, and the first
    /// video's poster queued.
    private func makeCover(_ id: String, folder: URL, from videos: [URL]) async {
        guard let view else { return }
        let store = folderPictures.store
        let pictures = await Task.detached(priority: .utility) { videos.compactMap { store.image(for: $0) } }.value
        guard !Task.isCancelled else { return }
        guard !pictures.isEmpty else {
            view.stopWaiting(for: [id])
            if !thumbnailsPaused, let first = videos.first, coverFor[first.path] == nil {
                coverFor[first.path] = (id, folder)
                folderPictures.enqueue(first)
            }
            return
        }
        let width = view.coverWidth, scale = view.window?.backingScaleFactor ?? 2
        let mosaic = await Task.detached(priority: .utility) {
            HomeMosaic.make(pictures, size: CGSize(width: width, height: width), layout: pictures.count > 1 ? .grid : .single,
                            scale: scale)
        }.value
        guard !Task.isCancelled else { return }
        if let mosaic { view.setImage(mosaic, for: id) } else { view.stopWaiting(for: [id]) }
    }

    private func coverPosterMade(_ url: URL) {
        guard let card = coverFor.removeValue(forKey: url.path), let facts = folderFacts[card.folder] else { return }
        Task { @MainActor [weak self] in await self?.makeCover(card.id, folder: card.folder, from: facts.cover) }
    }

    /// A file's facts are new: its card in view shows them at once (`setFacts`); a new length updates the listing
    /// through its open stream, once for a burst. Reloading the browser would discard every card and picture.
    private func factsFound(_ url: URL, _ found: FileFacts) {
        guard facts[url.path] != found else { return }
        let hadLength = facts[url.path]?.duration != nil
        facts[url.path] = found
        if view?.location == .source(HomeRecent.source) {
            view?.setFacts(["recent:" + url.path: found])
        } else {
            view?.setFacts([url.path: found])
        }
        guard !hadLength, found.duration != nil, positions[url.path]?.duration == nil else { return }
        relist?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.publishListing()
        }
        relist = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func publishListing() {
        guard let active = activeListing, view?.location == active.location else { return }
        let entries: [BrowserEntry]
        switch active.location {
        case .folder(let folder):
            guard let kept = listings[folder] else { return }
            entries = withFacts(kept)
            folderVideos = entries.filter(\.isFile).map(\.url)
        case .source(HomeRecent.source):
            entries = HomeRecent.entries(recentURLs(), resume: { positions[$0.path] }, facts: facts, dimmed: recentDimmed)
                .filter { !unreadable.contains($0) }
        default: return
        }
        active.continuation.yield(BrowserListing(entries: entries, complete: true))
    }

    private func pictureFailed(_ url: URL, _ failure: RecentThumbnailer.Failure) {
        if failure.marksUnreadable, let identity = failure.identity {
            let entry = listings[url.deletingLastPathComponent()]?.first { $0.url == url }
            let sameSize = entry?.size.map { $0 == identity.size } ?? true
            let sameDate = entry?.date.map { $0 == identity.modificationDate } ?? true
            if sameSize && sameDate {
                unreadable.mark(url, date: identity.modificationDate, size: identity.size)
                publishListing()
            } else if let active = activeListing, case .folder(let folder) = active.location {
                readFolder(folder, id: active.id) // another version is listed: reconcile before judging it
            }
        }
        if let card = coverFor.removeValue(forKey: url.path) { view?.stopWaiting(for: [card.id]) }
        posterIn(url) // transient read failures finish the attempt too, without being labelled damaged
        showProgress()
    }

    // MARK: Cards

    func menu(for entry: BrowserEntry, in location: BrowserLocation) -> [HomeMenuItem] {
        var items = [HomeMenuItem(id: "information", title: "File Information…"),
                     HomeMenuItem(id: "finder", title: "Show in Finder"), HomeMenuItem(id: "copy", title: "Copy Path")]
        if !entry.isFile { items.removeAll { $0.id == "information" } }
        if location == .source(HomeRecent.source) { items.append(HomeMenuItem(id: "remove", title: "Remove from Recent")) }
        return items
    }

    func perform(_ item: String, on entry: BrowserEntry, in location: BrowserLocation) {
        if item == "information", entry.isFile {
            if metadataInspector == nil { metadataInspector = MediaMetadataInspector() }
            metadataInspector?.show(entry)
        } else { onMenu?(entry.url, item) }
    }

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

    /// Recent: newest first, or as the user last sorted it this run; a folder: its own order, kept across runs and
    /// shared with the player's list, else `playlist-sort`'s.
    func sort(for location: BrowserLocation) -> BrowserSort {
        if case .folder(let folder) = location { return folderSorts.sort(for: folder) ?? defaultSort() }
        return sorts[location] ?? (location == .source(HomeRecent.source) ? BrowserSort(key: .date, ascending: false) : .standard)
    }

    func setSort(_ sort: BrowserSort, for location: BrowserLocation) {
        if case .folder(let folder) = location { folderSorts.set(sort, for: folder) } else { sorts[location] = sort }
    }

    func info(for source: String) -> HomeSourceInfo {
        source == HomeRecent.stash
            ? HomeSourceInfo(title: "Stash", page: stashPage())
            : HomeSourceInfo(title: "Recent", sortKeys: [.date, .name], groupsByDate: true, noun: "video",
                             emptyHint: "Drop a video here or press ⌘O to open one")
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

    /// Folder cards get their facts and covers from here: they wait, shimmering, until they come.
    var sendsCardFacts: Bool { true }

    func moved(from old: BrowserLocation?, to new: BrowserLocation) {
        if old != new {
            thumbnailsPaused = false
            folderCardIDs = []
            stopImages(keepingListing: true)
        }
    }

    // MARK: Recent

    /// Recent at once from the stores, then again with the files whose share does not answer in a second dimmed
    /// (only when there are any).
    private func listRecent() -> AsyncThrowingStream<BrowserListing, Error> {
        let urls = recentURLs()
        recentDimmed = []
        let first = HomeRecent.entries(urls, resume: { positions[$0.path] }, facts: facts, dimmed: [])
        let store = factsStore
        return AsyncThrowingStream { continuation in
            let id = self.keepListing(continuation, at: .source(HomeRecent.source))
            continuation.yield(BrowserListing(entries: first.filter { !self.unreadable.contains($0) }, complete: true))
            let task = Task { @MainActor [weak self] in
                let loaded = await Task.detached(priority: .utility) {
                    let resume = ResumeStore()
                    let positions = Dictionary(urls.compactMap { url in resume.entry(for: url).map { (url.path, $0) } },
                                               uniquingKeysWith: { a, _ in a })
                    return (store.facts(for: urls), positions)
                }.value
                guard let self, !Task.isCancelled else { continuation.finish(); return }
                for url in urls { self.facts[url.path] = loaded.0[url.path]; self.positions[url.path] = loaded.1[url.path] }
                if self.view?.location == .source(HomeRecent.source) {
                    self.view?.setLastViewed(Dictionary(loaded.1.compactMap { path, entry in
                        entry.lastViewedAt.map { (URL(fileURLWithPath: path), $0) }
                    }, uniquingKeysWith: { a, _ in a }))
                }
                let entries = HomeRecent.entries(urls, resume: { loaded.1[$0.path] }, facts: loaded.0, dimmed: [])
                continuation.yield(BrowserListing(entries: entries.filter { !self.unreadable.contains($0) }, complete: true))
                let reachable = await PathAvailability.check(urls.map(\.path), timeout: .seconds(1))
                let gone = Set(urls.map(\.path).filter { reachable[$0] == .some(false) })
                if !gone.isEmpty, !Task.isCancelled {
                    self.recentDimmed = gone
                    continuation.yield(BrowserListing(entries: HomeRecent.entries(urls, resume: { loaded.1[$0.path] },
                                                                                 facts: loaded.0, dimmed: gone).filter { !self.unreadable.contains($0) }, complete: true))
                }
            }
            continuation.onTermination = { [weak self] _ in
                task.cancel()
                Task { @MainActor in self?.endListing(id) }
            }
        }
    }
}
