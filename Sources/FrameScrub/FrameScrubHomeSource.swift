import AppKit
import EverythingSearchUI
import FrameScrubCore
import HomeScreenKit
import HomeScreenModel

/// Home's source (Home spec, Source): Recent's video cards, the places and folders, and Stash's page. Recent is read
/// afresh on each listing, dimmed once its shares answer; a folder is read off the main thread, its last listing shown
/// at once on the way back. Clicks and menus go back to the window.
@MainActor final class FrameScrubHomeSource: HomeSource {
#if DEBUG
    var benchRecentPicture: ((String, CGImage) -> Void)?
    private(set) var benchRecentListings = 0
#endif
    private static let everythingID = "everything"
    var onEverythingOpen: ((URL) -> Void)?
    private lazy var everythingPage = EverythingSearchPage(loadConnection: SavedEverythingConnection.load) { [weak self] url, isFolder in
        if isFolder { self?.view?.show(.folder(url), selecting: nil) }
        else { self?.onEverythingOpen?(url) }
    }

    var everythingHasKeyboardFocus: Bool {
        view?.location == .source(Self.everythingID) && everythingPage.containsKeyboardFocus
    }

    weak var view: HomeBrowserView?
    var catalogs: [String: PluginCatalogSource] = [:]
    var onCut: ((PluginCatalogSource, String, Bool) -> Void)?
    var onCatalogNavigation: (() -> Void)?
    var onSidebarChange: (() -> Void)?
    var filesInUse: (() -> [URL])?
    private var changingFiles = false

    private func catalog(_ location: BrowserLocation) -> PluginCatalogSource? {
        guard case let .source(id) = location else { return nil }
        return catalogs[id]
    }

    /// A video card opened (any click: one window), from Recent or from a folder, with the sort it was shown in.
    var onOpen: ((URL, BrowserLocation, BrowserSort) -> Void)?
    /// A card's menu item: `finder`, `copy`, and Recent's `remove`.
    var onMenu: ((URL, String) -> Void)?

    private let recentURLs: () -> [URL]
    private let stashPage: () -> NSView?
    private let hasStash: () -> Bool
    private let unreadable: UnreadableFiles
    private let folderMonitor = FolderChangeMonitor()
    private let favorites = FolderFavorites()
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
    private var favoriteCoverEntries: [BrowserEntry] = []
    private var coverGeneration = 0
    /// A video whose poster is being made for a folder's cover, and that folder card's id.
    private var coverFor: [String: (id: String, folder: URL)] = [:]
    private typealias ListingContinuation = AsyncThrowingStream<BrowserListing, Error>.Continuation
    /// Metadata updates go through the existing subscription, keeping the grid, pictures and scroll alive.
    private var activeListing: (id: UUID, location: BrowserLocation, continuation: ListingContinuation, flag: CancellationFlag, needsPictures: Bool, recursive: Bool)?
    private var recursiveEntries: [BrowserEntry]?
    private var recentDimmed: Set<String> = []
    private var relist: DispatchWorkItem?

    private func keepListing(_ continuation: ListingContinuation, at location: BrowserLocation, recursive: Bool = false) -> UUID {
        let old = activeListing
        if old?.location == location, old?.recursive != recursive { stopImages(keepingListing: true) }
        let id = UUID()
        activeListing = (id, location, continuation, CancellationFlag(), true, recursive)
        recursiveEntries = nil
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
            queue.onPicture = { [weak self] id, image in
                guard let self, let view, !view.isHiddenOrHasHiddenAncestor else { return }
                view.setImage(image, for: id)
#if DEBUG
                if let benchRecentPicture, id.hasPrefix("recent:"), view.visibleIDs.contains(id) {
                    benchRecentPicture(id, image)
                }
#endif
            }
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
        case .source(HomeFavorites.sourceID):
            stopImages(keepingListing: true)
            favoriteCoverEntries = []
            return AsyncThrowingStream { continuation in
                let id = keepListing(continuation, at: location)
                let task = Task { [weak self] in
                    guard let self else { continuation.finish(); return }
                    let rows = await favoriteRows()
                    guard !Task.isCancelled, activeListing?.id == id else { return }
                    let entries = HomeFavorites.entries(from: rows)
                    favoriteCoverEntries = entries
                    for entry in entries { folderFacts[entry.url] = nil }
                    continuation.yield(BrowserListing(entries: entries, complete: true))
                    continuation.finish()
                }
                continuation.onTermination = { [weak self] _ in
                    task.cancel()
                    Task { @MainActor in self?.endListing(id) }
                }
            }
        case .source: return catalog(location)?.listing() ?? AsyncThrowingStream { $0.finish() }
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

    func supportsRecursiveListing(in folder: URL) -> Bool { folder.isFileURL }

    func listRecursively(in folder: URL) -> AsyncThrowingStream<BrowserListing, Error> {
        listFolder(folder, recursive: true)
    }

    /// The kept listing at once (marked provisional), then the folder as read now, off the main thread.
    /// The stream stays open for metadata updates until the browser leaves or explicitly reloads it.
    private func listFolder(_ folder: URL, recursive: Bool = false) -> AsyncThrowingStream<BrowserListing, Error> {
        let kept = recursive ? nil : listings[folder]
        return AsyncThrowingStream { continuation in
            let id = self.keepListing(continuation, at: .folder(folder), recursive: recursive)
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
        let recursive: Bool
    }

    /// A stale SMB read can hold one slot while the current tab reads in the other. Further requests replace
    /// one pending read, and changes to one listing never read it twice at the same time.
    private lazy var folderReader = LatestOnlyWorker<FolderRead>(
        label: "framescrub.home-listing", qos: .utility, limit: 2, canRunTogether: { $0.id != $1.id }
    ) { [weak self] request in
        guard !request.flag.isCancelled else { return }
        if request.recursive, let cached = try? MediaCatalog.shared.recursiveListing(in: request.folder),
           !request.flag.isCancelled {
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.activeListing?.id == request.id, self.recursiveEntries == nil,
                          !request.flag.isCancelled else { return }
                    self.activeListing?.continuation.yield(
                        BrowserListing(entries: self.withFacts(cached), complete: true, isProvisional: true))
                }
            }
        }
        guard !request.flag.isCancelled else { return }
        let scannedAt = Date()
        do {
            let entries = if request.recursive {
                try RecursiveFolderFiles.read(in: request.folder, extensions: Playlist.videoExtensions,
                                              cancelled: { request.flag.isCancelled })
            } else {
                try HomeFolders.entries(in: request.folder)
            }
            guard !request.flag.isCancelled else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.folderEntries(entries, request: request) }
            }
            if request.recursive {
                try? MediaCatalog.shared.storeRecursiveListing(entries, in: request.folder, scannedAt: scannedAt)
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
        folderReader.submit(FolderRead(folder: folder, id: id, flag: active.flag, recursive: active.recursive))
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
        let previous = request.recursive ? recursiveEntries : listings[request.folder]
        let old = Dictionary((previous ?? []).map { ($0.url, $0) }, uniquingKeysWith: { a, _ in a })
        if request.recursive {
            recursiveEntries = entries
        } else {
            listings[request.folder] = entries
            folderFacts[request.folder] = nil
        }
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
        refreshSidebar()
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
        if let catalog = catalog(location) { return catalog.lastListing }
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
        case .folder, .archive, .collection: "folder"
        case .file: "film"
        }
    }

    // MARK: Pictures

    func playbackPictureSaved(_ image: CGImage, for url: URL) {
        guard view?.location == .source(HomeRecent.source) else { return }
        recentPictures.playbackPictureSaved(image, for: url)
    }

    /// The cards' pictures, those in view first: saved ones read off the main thread, the others made in the
    /// background one at a time.
    func wantImages(_ ids: [String], width: CGFloat) {
        // A layout callback can arrive after parking Home and stopping the current picture queues.
        guard let view, !view.isHiddenOrHasHiddenAncestor else { return }
        let location = view.location
        if let catalog = catalog(location) {
            catalog.want(ids) { [weak self] id, image in
                guard let view = self?.view, !view.isHiddenOrHasHiddenAncestor, view.location == location else { return }
                view.setImage(image, for: id)
            }
            return
        }
        if location == .source(HomeRecent.source) {
            recentPictures.want(ids)
        } else if location == .source(HomeFavorites.sourceID) {
            wantFolderCards(ids, entries: favoriteCoverEntries)
        } else {
            guard case .folder(let folder) = location else { return }
            let videos = withFacts(shownEntries(in: folder) ?? []).filter(\.isFile).map(\.url)
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
        guard let view, case .folder = view.location else { return }
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
        coverGeneration += 1
        for catalog in catalogs.values { catalog.stop() }
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

    /// Show cached posters first, then list the folders one at a time for summaries and refreshed covers.
    private func wantFolderCards(_ ids: [String], in folder: URL) {
        guard activeListing?.recursive != true, let entries = listings[folder] else { return }
        wantFolderCards(ids, entries: entries)
    }

    private func wantFolderCards(_ ids: [String], entries: [BrowserEntry]) {
        let byID = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let folders = ids.compactMap { byID[$0] }.filter { $0.kind == .folder }
        folderCardIDs = folders.filter { !$0.isDimmed }.map(\.id)
        factsTask?.cancel()
        let store = folderPictures.store, generation = coverGeneration
        factsTask = Task { @MainActor [weak self] in
            // A slow listing must not hold up cached covers for the other cards.
            for entry in folders {
                guard !Task.isCancelled else { return }
                let url = entry.url
                let pictures = await Task.detached(priority: .utility) { store.cachedFolderCover(in: url) }.value
                guard let self, !Task.isCancelled else { return }
                if !pictures.isEmpty { await self.showCover(pictures, for: entry.id, generation: generation) }
            }
            for entry in folders where !entry.isDimmed {
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
        let generation = coverGeneration
        let store = folderPictures.store
        let pictures = await Task.detached(priority: .utility) { videos.compactMap { store.image(for: $0) } }.value
        guard !Task.isCancelled, coverGeneration == generation else { return }
        guard !pictures.isEmpty else {
            if videos.isEmpty { view.setImage(nil, for: id) }
            view.stopWaiting(for: [id])
            if !thumbnailsPaused, let first = videos.first, coverFor[first.path] == nil {
                coverFor[first.path] = (id, folder)
                folderPictures.enqueue(first)
            }
            return
        }
        await showCover(pictures, for: id, generation: generation)
    }

    private func showCover(_ pictures: [CGImage], for id: String, generation: Int) async {
        guard let view, !Task.isCancelled, coverGeneration == generation else { return }
        let width = view.coverWidth, scale = view.window?.backingScaleFactor ?? 2
        let height = view.location == .source(HomeFavorites.sourceID) ? (width / view.files.aspect).rounded() : width
        let mosaic = await Task.detached(priority: .utility) {
            HomeMosaic.make(pictures, size: CGSize(width: width, height: height), layout: pictures.count > 1 ? .grid : .single,
                            scale: scale)
        }.value
        guard !Task.isCancelled, coverGeneration == generation, view.coverWidth == width else { return }
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

    private func shownEntries(in folder: URL) -> [BrowserEntry]? {
        activeListing?.recursive == true ? recursiveEntries : listings[folder]
    }

    private func publishListing() {
        guard let active = activeListing, view?.location == active.location else { return }
        let entries: [BrowserEntry]
        switch active.location {
        case .folder(let folder):
            guard let kept = shownEntries(in: folder) else { return }
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
            let candidates = activeListing?.recursive == true ? recursiveEntries : listings[url.deletingLastPathComponent()]
            let entry = candidates?.first { $0.url == url }
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
        if catalog(location) != nil { return [HomeMenuItem(id: "edit-virtual-cut", title: "Edit Cut…")] }
        let selection = menuSelection(for: entry)
        let fileItems = FileViewClipboard.folder(in: location) == nil ? [] : fileMenu(for: selection)
        if fileItems.count > 0, selection.count > 1 { return fileItems }
        var items = [HomeMenuItem(id: "information", title: "File Information…"),
                     HomeMenuItem(id: "finder", title: "Show in Finder"), HomeMenuItem(id: "copy", title: "Copy Path")]
        if !entry.isFile { items.removeAll { $0.id == "information" } }
        if entry.kind == .folder || entry.kind == .place { items.append(favoriteMenu(for: entry.url)) }
        if location == .source(HomeRecent.source) { items.append(HomeMenuItem(id: "remove", title: "Remove from Recent")) }
        return items + fileItems
    }

    func perform(_ item: String, on entry: BrowserEntry, in location: BrowserLocation) {
        if let catalog = catalog(location) {
            if item == "edit-virtual-cut" { onCut?(catalog, entry.id, true) }
            return
        }
        if entry.kind == .folder || entry.kind == .place, performFavoriteMenu(item, for: entry.url) { return }
        if let folder = FileViewClipboard.folder(in: location) {
            switch item {
            case "copy-files": FileViewClipboard.copy(menuSelection(for: entry)); return
            case "paste-files", "move-files": pasteFiles(into: folder, moving: item == "move-files"); return
            case "trash-files": trashFiles(menuSelection(for: entry)); return
            default: break
            }
        }
        if item == "information", entry.isFile {
            if metadataInspector == nil { metadataInspector = MediaMetadataInspector() }
            metadataInspector?.show(entry)
        } else { onMenu?(entry.url, item) }
    }

    private func menuSelection(for entry: BrowserEntry) -> [BrowserEntry] {
        guard let selected = view?.selectedEntries, selected.contains(where: { $0.id == entry.id }) else { return [entry] }
        return selected
    }

    private func fileMenu(for selection: [BrowserEntry]) -> [HomeMenuItem] {
        var items = [HomeMenuItem(id: "copy-files", title: "Copy")]
        if FileViewClipboard.hasFiles {
            items += [HomeMenuItem(id: "paste-files", title: "Paste Items"),
                      HomeMenuItem(id: "move-files", title: "Move Items Here")]
        }
        if selection.contains(where: \.canTrash) { items.append(HomeMenuItem(id: "trash-files", title: "Move to Trash")) }
        return items
    }

    func pasteFiles(into folder: URL, moving: Bool) {
        let files = FileViewClipboard.files()
        changeFiles(moving ? .move(into: folder) : .copy(into: folder), urls: files, verb: moving ? "Moved" : "Copied")
    }

    func trashFiles(_ entries: [BrowserEntry]) {
        changeFiles(.trash, urls: entries.filter(\.canTrash).map(\.url), verb: "Removed")
    }

    private func changeFiles(_ command: FileViewFileActions.Command, urls: [URL], verb: String) {
        guard !urls.isEmpty else { return }
        guard !changingFiles else {
            view?.showToast("A file operation is already in progress.")
            return
        }
        changingFiles = true
        let protected = filesInUse?() ?? []
        Task {
            var report = await Task.detached(priority: .utility) {
                FileViewFileActions.run(command, urls: urls, protected: protected)
            }.value
            if let first = report.needsConfirmation.first {
                let remaining = report.needsConfirmation
                if await confirmPermanentRemoval(count: remaining.count, first: first) {
                    let protected = filesInUse?() ?? []
                    let result = await Task.detached(priority: .utility) {
                        FileViewFileActions.run(.delete, urls: remaining, protected: protected)
                    }.value
                    report.completed += result.completed
                    report.failures += result.failures
                    if report.firstError == nil { report.firstError = result.firstError }
                    report.parents.formUnion(result.parents)
                } else {
                    report.unchanged += remaining.count
                }
            }
            changingFiles = false
            finishFileChange(report, verb: verb)
        }
    }

    private func confirmPermanentRemoval(count: Int, first: URL) async -> Bool {
        guard let window = view?.window, window.isVisible, window.attachedSheet == nil else { return false }
        let alert = NSAlert()
        alert.messageText = "Delete permanently?"
        alert.informativeText = count == 1
            ? "“\(first.lastPathComponent)” is on a volume without a Trash. It will be deleted right away."
            : "\(count) items are on volumes without a Trash. They will be deleted right away."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\r"
        alert.addButton(withTitle: "Delete").hasDestructiveAction = true
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { continuation.resume(returning: $0 == .alertSecondButtonReturn) }
        }
    }

    private func finishFileChange(_ report: FileViewFileActions.Report, verb: String) {
        for (from, to) in report.movedFolders { _ = favorites.rename(from, to: to) }
        if !report.parents.isEmpty {
            for folder in listings.keys where report.parents.contains(folder.standardizedFileURL.path) {
                listings.removeValue(forKey: folder)
                folderFacts[folder] = nil
            }
            refreshSidebar()
            if watchingVisible, let active = activeListing, case .folder(let folder) = active.location {
                let path = folder.standardizedFileURL.path
                let prefix = path == "/" ? path : path + "/"
                if report.parents.contains(path) || (active.recursive && report.parents.contains(where: { $0.hasPrefix(prefix) })) {
                    readFolder(folder, id: active.id)
                }
            }
        }
        var lines = ["\(verb) \(report.completed) \(report.completed == 1 ? "item" : "items")"]
        if report.unchanged > 0 { lines.append("\(report.unchanged) unchanged") }
        if let error = report.firstError { lines.append("\(report.failures) failed · \(error)") }
        view?.showToast(lines.joined(separator: "\n"), for: report.failures == 0 ? 3 : 6)
    }

    func open(_ entry: BrowserEntry, in location: BrowserLocation, sort: BrowserSort, how: HomeClick) {
        if let catalog = catalog(location) { onCut?(catalog, entry.id, false); return }
        guard entry.isFile else { return }
        onOpen?(entry.url, location, sort)
    }

    func rename(_ entry: BrowserEntry, to name: String) async throws -> BrowserEntry {
        let target = entry.url.deletingLastPathComponent().appendingPathComponent(name)
        try await Task.detached(priority: .userInitiated) { try FileManager.default.moveItem(at: entry.url, to: target) }.value
        listings[entry.url.deletingLastPathComponent()] = nil
        if entry.kind == .folder, favorites.rename(entry.url, to: target) { refreshSidebar() }
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
        if source == Self.everythingID { return HomeSourceInfo(title: "Everything", page: everythingPage) }
        if source == HomeFavorites.sourceID {
            return HomeSourceInfo(title: "Favorites", noun: "folder",
                                  emptyHint: "Control-click a folder and choose Add to Favorites.", preservesOrder: true)
        }
        if let catalog = catalogs[source] {
            return HomeSourceInfo(title: catalog.descriptor.title, sortKeys: [.name], noun: "cut",
                                  emptyHint: "Saved cuts appear here")
        }
        return source == HomeRecent.stash
            ? HomeSourceInfo(title: "Stash", page: stashPage())
            : HomeSourceInfo(title: "Recent", sortKeys: [.date, .name], groupsByDate: true, noun: "video",
                             emptyHint: "Drop a video here or choose File → Open (⌘O).")
    }

    // MARK: Favorites and sidebar

    func sidebarMenu(for row: HomeSidebarRow) -> [HomeMenuItem] {
        guard case .folder(let folder) = row.location,
              row.expandable || favorites.contains(folder) else { return [] }
        return [favoriteMenu(for: folder)]
    }

    func performSidebar(_ item: String, on row: HomeSidebarRow) {
        guard case .folder(let folder) = row.location,
              row.expandable || favorites.contains(folder) else { return }
        _ = performFavoriteMenu(item, for: folder)
    }

    func moveFavoriteFolder(_ folder: URL, before other: URL?) {
        if favorites.move(folder, before: other) { onSidebarChange?() }
    }

    private func favoriteMenu(for folder: URL) -> HomeMenuItem {
        favorites.contains(folder)
            ? HomeMenuItem(id: "favorite-remove", title: "Remove from Favorites")
            : HomeMenuItem(id: "favorite-add", title: "Add to Favorites")
    }

    private func performFavoriteMenu(_ item: String, for folder: URL) -> Bool {
        switch item {
        case "favorite-add":
            if favorites.add(folder) { refreshSidebar() }
        case "favorite-remove":
            if favorites.remove(folder) { refreshSidebar() }
        default: return false
        }
        return true
    }

    private var favoriteAvailabilityTask: Task<Void, Never>?
    private var favoriteRefreshPending = false
    private var hasRequestedFavoriteAvailability = false
    private var unavailableFavorites: Set<URL> = []

    private func checkFavoriteAvailability() {
        hasRequestedFavoriteAvailability = true
        let folders = favorites.folders
        unavailableFavorites.formIntersection(folders)
        if favoriteAvailabilityTask != nil {
            favoriteRefreshPending = true
            return
        }
        guard !folders.isEmpty else { return }
        favoriteAvailabilityTask = Task { [weak self] in
            let answers = await PathAvailability.checkDirectories(folders.map(\.path), timeout: .seconds(1))
            guard let self else { return }
            favoriteAvailabilityTask = nil
            let old = unavailableFavorites
            for folder in favorites.folders {
                guard let available = answers[folder.path] else { continue }
                if available { unavailableFavorites.remove(folder) }
                else { unavailableFavorites.insert(folder) }
            }
            if old != unavailableFavorites { onSidebarChange?() }
            if favoriteRefreshPending {
                favoriteRefreshPending = false
                checkFavoriteAvailability()
            }
        }
    }

    func refreshSidebar() {
        checkFavoriteAvailability()
        onSidebarChange?()
    }

    private func favoriteRows() async -> [HomeSidebarRow] {
        await favoriteRows(places: places().map {
            HomeSidebarRow(id: $0.id, title: $0.name, symbol: symbol(for: $0), location: .folder($0.url))
        })
    }

    private func favoriteRows(places: [HomeSidebarRow]) async -> [HomeSidebarRow] {
        let startupDisk = await Task.detached(priority: .utility) {
            FileManager.default.displayName(atPath: "/")
        }.value
        let volumes = places.compactMap { row -> (URL, String)? in
            guard case .folder(let url) = row.location, row.symbol == "externaldrive" else { return nil }
            return (url, row.title)
        }
        let folders = favorites.folders
        let hints = HomeFavorites.locationHints(for: folders, volumes: volumes, startupDisk: startupDisk)
        return folders.map { folder in
            let available = !unavailableFavorites.contains(folder)
            return HomeSidebarRow(id: "favorite:" + folder.path, title: folder.path == "/" ? startupDisk : folder.lastPathComponent,
                                  symbol: "folder", location: .folder(folder), expandable: available, isDimmed: !available,
                                  locationHint: hints[folder])
        }
    }

    /// Recent; Favorites and Places, each opening as a tree; Stash's library when `stash-url` is set.
    func sidebar() async -> [HomeSidebarSection] {
        if !hasRequestedFavoriteAvailability { checkFavoriteAvailability() }
        let places = await places().map {
            HomeSidebarRow(id: $0.id, title: $0.name, symbol: symbol(for: $0), location: .folder($0.url), expandable: true)
        }
        var sections = [
            HomeSidebarSection(id: "library", title: nil, rows: [
                HomeSidebarRow(id: HomeRecent.source, title: "Recent", symbol: "clock", location: .source(HomeRecent.source)),
                HomeFavorites.sourceRow,
            ]),
            HomeSidebarSection(id: "places", title: "Places", rows: places),
        ]
        let favoriteRows = await favoriteRows(places: places)
        if !favoriteRows.isEmpty { sections.insert(.favorites(favoriteRows), at: 1) }
        if hasStash() {
            sections.append(HomeSidebarSection(id: "stash", title: "Stash", rows: [
                HomeSidebarRow(id: HomeRecent.stash, title: "Library", symbol: "server.rack", location: .source(HomeRecent.stash)),
            ]))
        }
        if !catalogs.isEmpty {
            let rows = catalogs.values.sorted { $0.locationID < $1.locationID }.map {
                HomeSidebarRow(id: $0.locationID, title: $0.descriptor.title, symbol: "film.stack",
                               location: .source($0.locationID))
            }
            sections.append(HomeSidebarSection(id: "plugins", title: "Plugins", rows: rows))
        }
        if await SavedEverythingConnection.isConfigured() {
            sections[0].rows.append(HomeSidebarRow(id: Self.everythingID, title: "Everything", symbol: "magnifyingglass",
                                                  location: .source(Self.everythingID)))
        }
        return sections
    }

    func pageFilterChosen(_ index: Int, in source: String) {}

    /// Folder cards get their facts and covers from here: they wait, shimmering, until they come.
    var sendsCardFacts: Bool { true }

    func moved(from old: BrowserLocation?, to new: BrowserLocation) {
        if old != new {
            if let old, catalog(old) != nil { onCatalogNavigation?() }
            thumbnailsPaused = false
            folderCardIDs = []
            stopImages(keepingListing: true)
        }
    }

    // MARK: Recent

    /// Recent at once from the stores, then again with the files whose share does not answer in a second dimmed
    /// (only when there are any).
    private func listRecent() -> AsyncThrowingStream<BrowserListing, Error> {
#if DEBUG
        if benchRecentPicture != nil { benchRecentListings += 1 }
#endif
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
