import AppKit
import FrameScrubCore
import HomeScreenModel

/// One kind of card picture: saved ones read off the main thread in the order asked, the missing ones made by a
/// thumbnailer (one file at a time, `.utility`), whose run is left going when an ask brings nothing new (a new start
/// would cancel the file being made). Card ids are `prefix` + the file's path.
@MainActor final class PictureQueue {
    var onPicture: ((String, CGImage) -> Void)?
    var onFacts: ((URL, FileFacts) -> Void)?
    /// Whether a file's facts are known: a kept picture without them gets a probe (no decode) after the pictures.
    var hasFacts: ((URL) -> Bool)?
    /// A picture was made (after `onPicture`), whoever asked for it.
    var onMade: ((URL) -> Void)?
    /// A file has its picture: found kept, or just made.
    var onHave: ((URL) -> Void)?

    let store: ThumbnailStore
    private let thumbnailer: RecentThumbnailer
    private let prefix: String
    /// Recent's keyframe is where the file was left; a folder's, a tenth in.
    private let atPosition: Bool
    private var reading: Task<Void, Never>?
    private var pending: [URL] = []
    /// Of `pending`, the files whose picture is kept: only their facts are wanted.
    private var factsOnly: Set<URL> = []

    init(store: ThumbnailStore, thumbnailer: RecentThumbnailer, prefix: String, atPosition: Bool) {
        self.store = store
        self.thumbnailer = thumbnailer
        self.prefix = prefix
        self.atPosition = atPosition
    }

    /// The cards `ids` (in view first) get their pictures; then the files of `rest` (a folder's other videos) are
    /// made ahead, after those, without being read.
    func want(_ ids: [String], rest: [URL] = []) {
        let store = store, idPrefix = prefix
        let urls = ids.filter { $0.hasPrefix(idPrefix) }
            .map { URL(filePath: String($0.dropFirst(idPrefix.count)), directoryHint: .notDirectory) }
            .filter { Playlist.videoExtensions.contains($0.pathExtension.lowercased()) }
        reading?.cancel()
        reading = Task { @MainActor [weak self] in
            var missing: [URL] = [], probes: [URL] = []
            for url in urls {
                let image = await Task.detached(priority: .utility) { store.image(for: url) }.value
                guard let self, !Task.isCancelled else { return }
                if let image {
                    self.onPicture?(idPrefix + url.path, image)
                    self.onHave?(url)
                    if self.hasFacts?(url) == false { probes.append(url) }   // a poster of a run before the facts
                } else {
                    missing.append(url)
                }
            }
            let asked = Set(urls)
            let ahead = rest.filter { !asked.contains($0) }
            let kept = await Task.detached(priority: .background) { Set(ahead.filter { store.has($0) }) }.value
            guard let self, !Task.isCancelled else { return }
            for url in kept { self.onHave?(url) }
            missing += ahead.filter { !kept.contains($0) }
            let waiting = Set(self.pending)   // a folder can hold thousands: sets, not array scans
            let newProbes = probes.filter { !waiting.contains($0) }
            self.factsOnly.formUnion(newProbes)
            let new = missing.filter { !waiting.contains($0) } + newProbes   // the probes after the pictures in view
            guard !new.isEmpty else { return }
            let first = Set(new)
            self.pending = new + self.pending.filter { !first.contains($0) }   // what is in view first
            self.startPending()
        }
    }

    private func startPending() {
        let resume = atPosition ? ResumeStore() : nil
        let jobs = pending.map {
            RecentThumbnailer.Job(url: $0, seconds: resume?.entry(for: $0).flatMap { $0.position > 0 ? $0.position : nil },
                                  factsOnly: factsOnly.contains($0))
        }
        thumbnailer.start(jobs, localWorkers: atPosition ? 1 : RecentThumbnailer.localWorkers) { [weak self] url, facts in
            MainActor.assumeIsolated { self?.made(url, facts: facts) }
        }
    }

    /// One more file to make, after those waiting, without dropping the asks in progress.
    func enqueue(_ url: URL) {
        guard !pending.contains(url) else { return }
        pending.append(url)
        startPending()
    }

    /// Only `urls` are still wanted (the rows in view): the others waiting are dropped and the run restarts on what
    /// is left (which also restarts the file being made); nothing happens while every waiting file is still wanted.
    func retain(_ urls: Set<URL>) {
        let kept = pending.filter { urls.contains($0) }
        guard kept.count != pending.count else { return }
        pending = kept
        factsOnly.formIntersection(urls)
        if pending.isEmpty { thumbnailer.cancel() } else { startPending() }
    }

    func stop() {
        reading?.cancel()
        reading = nil
        pending = []
        factsOnly = []
        thumbnailer.cancel()
    }

    private func made(_ url: URL, facts: FileFacts) {
        pending.removeAll { $0 == url }
        onFacts?(url, facts)
        if factsOnly.remove(url) != nil { return }   // the picture was there already
        let store = store, id = prefix + url.path
        Task { @MainActor [weak self] in
            let image = await Task.detached(priority: .utility) { store.image(for: url) }.value
            if let image { self?.onPicture?(id, image) }
            self?.onHave?(url)
            self?.onMade?(url)
        }
    }
}
