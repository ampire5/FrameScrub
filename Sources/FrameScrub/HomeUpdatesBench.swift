import AppKit
import FrameScrubCore
import HomeScreenKit
import HomeScreenModel

/// A fresh video learns its duration after its card appears. That update must not put the card back in the pool.
@MainActor enum HomeUpdatesBench {
    static func run() -> Never {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 30) {
            FileHandle.standardError.write(Data("home-updates: benchmark did not finish within 30 seconds\n".utf8))
            exit(1)
        }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = temporary.appendingPathComponent("folder")
        let videos = (0..<5).map { folder.appendingPathComponent("video-\($0).mp4") }
        let damaged = folder.appendingPathComponent("z-damaged.mp4")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for video in videos {
                try FileManager.default.copyItem(at: URL(fileURLWithPath: "Tests/Fixtures/withaudio_gop25.mp4"), to: video)
            }
            try Data().write(to: damaged)
        } catch {
            FileHandle.standardError.write(Data("home-updates: cannot prepare fixture: \(error)\n".utf8))
            exit(2)
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.finishLaunching()
        let store = ThumbnailStore(directory: temporary.appendingPathComponent("recent"))
        let unreadable = UnreadableFiles()
        let source = FrameScrubHomeSource(folderSorts: FolderSorts(url: nil), defaultSort: { .standard },
                                         recentURLs: { [] }, thumbnails: store, thumbnailer: RecentThumbnailer(store: store),
                                         stashPage: { nil }, hasStash: { false }, unreadable: unreadable)
        let home = HomeView(source: source)
        source.view = home.browser
        home.browser.files = .videos
        home.browser.names = .below
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1000, height: 700),
                              styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.autorecalculatesKeyViewLoop = true
        window.contentView = home
        window.setContentSize(NSSize(width: 1000, height: 700))
        window.toolbar = home.browser.nsToolbar
        home.browser.show(.folder(temporary), selecting: nil)
        window.makeKeyAndOrderFront(nil)
        app.activate()
        Task { @MainActor in
            let cpu = StartupTrace.threadCPU()
            // Navigate while the parent's folder-cover work and listing cancellation can still be finishing.
            try? await Task.sleep(for: .milliseconds(100))
            home.browser.show(.folder(folder), selecting: nil)
            @MainActor func firstCard(_ view: NSView) -> NSView? {
                if String(describing: type(of: view)) == "PhotoCard", !view.isHidden { return view }
                return view.subviews.lazy.compactMap(firstCard).first
            }
            var card: NSView?
            for _ in 0..<100 {
                card = firstCard(home)
                if card != nil { break }
                try? await Task.sleep(for: .milliseconds(20))
            }
            guard let card else {
                FileHandle.standardError.write(Data("home-updates: card never appeared\n".utf8))
                exit(1)
            }
            var hides = 0
            let observation = card.observe(\.isHidden, options: [.new]) { _, change in
                if change.newValue == true { hides += 1 }
            }
            try? await Task.sleep(for: .seconds(2))
            let facts = await Task.detached(priority: .utility) {
                FileFactsStore.shared.facts(for: videos)
            }.value
            observation.invalidate()
            @MainActor func cardCount(_ view: NSView) -> Int {
                (String(describing: type(of: view)) == "PhotoCard" && !view.isHidden ? 1 : 0)
                    + view.subviews.reduce(0) { $0 + cardCount($1) }
            }
            let skippedDamaged = unreadable.contains(damaged, date: nil, size: 0) && cardCount(home) == 5
            source.pauseThumbs(true, in: .folder(folder))
            let pausedFile = folder.appendingPathComponent("paused.mp4")
            try? FileManager.default.copyItem(at: videos[0], to: pausedFile)
            try? await Task.sleep(for: .seconds(1))
            let pausedFacts = await Task.detached(priority: .utility) { FileFactsStore.shared.facts(for: [pausedFile]) }.value
            let stayedPaused = pausedFacts.isEmpty && cardCount(home) == 6
            source.pauseThumbs(false, in: .folder(folder))
            try? await Task.sleep(for: .seconds(1))
            let resumedFacts = await Task.detached(priority: .utility) { FileFactsStore.shared.facts(for: [pausedFile]) }.value
            let resumed = !resumedFacts.isEmpty
            try? FileManager.default.removeItem(at: pausedFile)
            try? await Task.sleep(for: .seconds(1))
            source.pauseThumbs(true, in: .folder(folder))
            let nested = folder.appendingPathComponent("nested")
            let coverVideo = nested.appendingPathComponent("video.mp4")
            try? FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            try? FileManager.default.copyItem(at: videos[0], to: coverVideo)
            try? await Task.sleep(for: .seconds(1))
            let coverFacts = await Task.detached(priority: .utility) { FileFactsStore.shared.facts(for: [coverVideo]) }.value
            let coverPaused = coverFacts.isEmpty
            source.pauseThumbs(false, in: .folder(folder))
            try? await Task.sleep(for: .seconds(1))
            let coverResumed = await Task.detached(priority: .utility) {
                ThumbnailStore(directory: ThumbnailStore.defaultDirectory.appendingPathComponent("posters"), limit: 2000,
                               maxSide: ThumbnailStore.configuredSide(poster: true)).has(coverVideo)
            }.value
            try? FileManager.default.removeItem(at: nested)
            try? await Task.sleep(for: .seconds(1))
            let automatic = folder.appendingPathComponent("automatic.mp4")
            try? FileManager.default.copyItem(at: videos[0], to: automatic)
            try? await Task.sleep(for: .seconds(1))
            let addedAutomatically = cardCount(home) == 6
            try? FileManager.default.removeItem(at: automatic)
            try? await Task.sleep(for: .seconds(1))
            let removedAutomatically = cardCount(home) == 5
            try? FileManager.default.removeItem(at: damaged)
            try? FileManager.default.copyItem(at: videos[0], to: damaged)
            try? await Task.sleep(for: .seconds(1))
            let repairedVisible = cardCount(home) == 6
            try? FileManager.default.removeItem(at: damaged)
            try? await Task.sleep(for: .seconds(1))
            // Refresh still works with event delivery paused (the keyboard's source action).
            source.setWatchingVisible(false)
            try? FileManager.default.copyItem(at: videos[0], to: automatic)
            source.refresh()
            try? await Task.sleep(for: .seconds(1))
            let refreshed = cardCount(home) == 6
            source.setWatchingVisible(true)
            home.isHidden = true
            home.isParked = true
            source.stopImages()
            let added = folder.appendingPathComponent("video-added.mp4")
            do { try FileManager.default.copyItem(at: videos[0], to: added) }
            catch { exit(2) }
            try? await Task.sleep(for: .milliseconds(100))
            home.isParked = false
            home.isHidden = false
            home.browser.show(.folder(folder), selecting: videos[0].path)
            try? await Task.sleep(for: .seconds(1))
            let returnedCount = cardCount(home)
            source.stopImages()
            try? FileManager.default.removeItem(at: temporary)
            let complete = facts.count == videos.count && facts.values.allSatisfy { $0.duration != nil }
            print("home-updates: durations learned=\(facts.count)/\(videos.count), card hidden=\(hides)")
            print("home-updates: empty skipped=\(skippedDamaged), auto add=\(addedAutomatically), auto remove=\(removedAutomatically), refresh=\(refreshed)")
            print("home-updates: pause respected=\(stayedPaused), resumed=\(resumed), repaired visible=\(repairedVisible)")
            print("home-updates: folder cover paused=\(coverPaused), folder cover resumed=\(coverResumed)")
            print("home-updates: cards after return=\(returnedCount), expected=7")
            print(String(format: "home-updates: %.1f ms main-thread CPU", StartupTrace.threadCPU() - cpu))
            exit(complete && hides == 0 && skippedDamaged && stayedPaused && resumed && coverPaused && coverResumed && repairedVisible
                 && addedAutomatically && removedAutomatically && refreshed && returnedCount == 7 ? 0 : 1)
        }
        app.run()
        exit(2)
    }
}
