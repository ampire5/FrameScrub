import AppKit
import Filmstrip
import FilmstripModel
import FrameScrubCore
import HomeChrome
import HomeScreenModel

/// The playlist as a vertical strip (`playlist-view = strip`, spec 2026-10-27-playlist-strip): a row per video with
/// its picture, name and facts, the row at the centre (the browsed one) larger with a card. Scrolling browses and opens
/// nothing; a click or ↩ opens; left alone, the strip goes back to the playing video (`PlaylistStripState`).
///
/// Pictures: the last frame seen (`ThumbnailStore`), else Home's poster, read off the main thread for the rows in view;
/// a missing poster is made only for a row that stays in view (`PosterDwell`), by Home's `PictureQueue`. Facts come
/// from `FileFactsStore.shared`, positions from `ResumeStore`, sizes and dates from the file system, all off the main
/// thread and only for the rows in view. At rest no timer runs.
@MainActor final class PlaylistStripView: NSView {
    /// A row was opened (a click, ↩): its index among the rows.
    var onSelect: ((Int) -> Void)?
    /// `playlist-strip-return`.
    var returnDelay: Double = 3 {
        didSet {
            guard returnDelay != oldValue else { return }
            state.setReturnDelay(returnDelay, now: now)
            armReturn()
        }
    }

    /// A plain row's picture, of the strip's width; the browsed row's spans the strip.
    static let rowPictureShare = 0.55

    private var rowPicture: Double { max(80, (Double(bounds.width) * Self.rowPictureShare).rounded()) }

    private let strip = FilmstripRowsView()
    private let card = PlaylistCardView()
    private var scroll = FilmstripScroll()
    private var state = PlaylistStripState(returnDelay: 3)
    private var dwell = PosterDwell()
    private var rows: [PlaylistRow] = []
    private var playingRow: Int?
    /// What is known of each file; filled off the main thread, only for rows that were in view.
    private var facts: [URL: FileFacts] = [:]
    private var fileInfo: [URL: FileInfo] = [:]
    /// Files whose picture was looked for in the stores (found or not), and those that have one.
    private var looked: Set<URL> = []
    private var hasPicture: Set<URL> = []
    /// Files given to the poster queue since the rows last changed.
    private var asked: Set<URL> = []
    private var reading: Task<Void, Never>?
    private var restTimer: Timer?
    private var returnTimer: Timer?
    private var dwellTimer: Timer?
    private var readTimer: Timer?
    /// How long the rows in view stay put before they are read.
    static let readDelay = 0.1
    private var relayoutPending = false
    private var cardHeight = 0.0
    private var pointerInside = false
    private var trackingArea: NSTrackingArea?

    private let lastFrames = ThumbnailStore()
    private let posters: PictureQueue = {
        let store = ThumbnailStore(directory: ThumbnailStore.defaultDirectory.appendingPathComponent("posters"),
                                   limit: 2000, maxSide: ThumbnailStore.configuredSide(poster: true))
        return PictureQueue(store: store, thumbnailer: RecentThumbnailer(store: store), prefix: "", atPosition: false)
    }()

    private struct FileInfo: Sendable {
        var size: Int64?
        var date: Date?
        var resume: ResumeEntry?
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        strip.translatesAutoresizingMaskIntoConstraints = false
        addSubview(strip)
        NSLayoutConstraint.activate([
            strip.leadingAnchor.constraint(equalTo: leadingAnchor), strip.trailingAnchor.constraint(equalTo: trailingAnchor),
            strip.topAnchor.constraint(equalTo: topAnchor), strip.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        strip.card = card
        strip.selectionHint = "Selected · click or Return to play"
        strip.onBrowse = { [weak self] row in
            guard let self else { return }; scroll.settle()
            state.browse(to: row, now: now, inGesture: false)
            place(animated: false); armReturn()
        }
        strip.onVisibleChange = { [weak self] in self?.visibleChanged() }
        strip.onPress = { [weak self] row in self?.open(row) }
        strip.onPressBegan = { [weak self] in self?.pressBegan() }
        strip.onDrag = { [weak self] dy in self?.dragged(by: dy) }
        strip.onDragEnd = { [weak self] in self?.settle() }
        strip.onStripScroll = { [weak self] event in self?.scrolled(event) }
        card.onPress = { [weak self] in self?.openBrowsed() }
        posters.onPicture = { [weak self] id, image in self?.picture(image, for: URL(filePath: id)) }
        posters.onFacts = { [weak self] url, found in self?.learned(found, for: url) }
        posters.hasFacts = { [weak self] url in self?.facts[url] != nil }

    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: Rows

    /// The playlist's rows; `current` the playing one's index, -1 when it is not shown.
    func update(rows: [PlaylistRow], current: Int) {
        let playing = rows.indices.contains(current) ? current : nil
        guard rows != self.rows || playing != playingRow else { return }
        let changed = rows != self.rows
        let map = changed ? FilmstripItems.indexMap(from: PlaylistRow.identities(self.rows), to: PlaylistRow.identities(rows))
            : identityMap
        // The video left: its position and last frame are new, read them again when its row is in view.
        if let old = playingRow, old != playing, self.rows.indices.contains(old), let url = self.rows[old].url {
            looked.remove(url)
            fileInfo[url] = nil
        }
        self.rows = rows
        playingRow = playing
        let wasBrowsed = state.browsed
        state.rowsChanged(count: rows.count, playing: playing, map: map)
        if changed {
            strip.remap(map)
            // A file filtered out loses its picture in the strip: when it comes back, it is looked at again.
            let present = Set(rows.compactMap(\.url))
            looked.formIntersection(present)
            hasPicture.formIntersection(present)
            dwell.reset()
            asked = []
            relayout()
        }
        strip.playing = playing
        if scroll.isMoving, state.browsed != wasBrowsed { scroll.settle() }
        place(animated: !changed && window != nil)
        refreshState()
    }

    /// A file's name without its extension; a page's own title as it gave it.
    private static func title(_ row: PlaylistRow) -> String {
        guard let url = row.url, row.title == url.lastPathComponent else { return row.title }
        return url.deletingPathExtension().lastPathComponent
    }

    private var identityMap: [Int: Int] { Dictionary(uniqueKeysWithValues: rows.indices.map { ($0, $0) }) }

    /// ↑ / ↓ (and ⇞ / ⇟) in the filter field: the browsed row moves by `rows`.
    func step(by count: Int) {
        guard let browsed = state.browsed else { return }
        scroll.settle()
        state.browse(to: browsed + count, now: now, inGesture: false)
        place(animated: true)
        armReturn()
    }

    /// A screenful of plain rows, for ⇞ / ⇟.
    var pageRows: Int {
        let row = rowPicture * 9 / 16 + FilmstripRowsView.captionHeight + FilmstripRows.gapRatio * rowPicture
        return max(1, Int(Double(bounds.height) / row) - 1)
    }

    /// Whether the browsed row is the playing one (↩ then keeps today's "the first other match").
    var browsedIsPlaying: Bool { state.browsed != nil && state.browsed == playingRow }

    /// The filter's text changed or it lost the keyboard: the return waits from now.
    func filterEdited() {
        refreshState()
    }

    /// ↩ in the filter field: the browsed row opens.
    func openBrowsed() {
        guard let browsed = state.browsed else { return }
        open(browsed)
    }

    private func open(_ row: Int) {
        guard rows.indices.contains(row) else { return }
        scroll.settle()
        // The playing row: nothing to open (the table never reloaded the open video either).
        guard row != playingRow else {
            refreshState()
            place(animated: true)
            return
        }
        state.opened(row)
        playingRow = row
        strip.playing = row
        place(animated: true)
        armReturn()
        onSelect?(row)
    }

    // MARK: Layout

    override func setFrameSize(_ newSize: NSSize) {
        let old = frame.size
        super.setFrameSize(newSize)
        if newSize != old { relayout() }
    }

    private func relayout() {
        relayoutPending = false
        let width = max(0, Double(bounds.width) - 20)
        let currentPicture = max(rowPicture, width - 2 * Double(FilmstripRowsView.padding))
        measureCard(width: currentPicture)
        let aspects: [Double?] = rows.map { row in
            guard let url = row.url, let f = facts[url], let w = f.width, let h = f.height, w > 0, h > 0 else { return nil }
            return Double(w) / Double(h)
        }
        let layout = FilmstripRows(itemCount: rows.count, aspects: aspects, length: Double(bounds.height), width: width,
                                   rowPicture: rowPicture, currentPicture: currentPicture, cardHeight: cardHeight,
                                   captionHeight: FilmstripRowsView.captionHeight,
                                   currentCaptionHeight: FilmstripRowsView.currentCaptionHeight)
        if let browsed = state.browsed { scroll.layoutChanged(keeping: browsed, layout: layout) }
        strip.layout = layout
        place(animated: false)
    }

    /// Facts arrive one by one: one relayout for a run of them, on the next turn of the run loop.
    private func relayoutSoon() {
        guard !relayoutPending else { return }
        relayoutPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self, self.relayoutPending else { return }
            self.relayout()
        }
    }

    private func place(animated: Bool) {
        guard let browsed = state.browsed, strip.layout.itemCount > 0 else {
            strip.show(offset: 0, current: 0, expansion: 0, animated: false)
            return
        }
        fillCard()
        strip.show(offset: scroll.offset ?? strip.layout.centre(of: browsed), current: browsed,
                   expansion: scroll.isMoving ? 0 : 1, animated: animated)
    }

    // MARK: The card

    /// The card's height does not depend on its width (the name takes two lines, the rest one each): measured once.
    private func measureCard(width: Double) {
        guard cardHeight == 0 else { return }
        card.fill(lines: ["line", "line", "line"])
        let height = card.fittingHeight(width: CGFloat(width))
        cardHeight = Double(height) + Double(FilmstripRowsView.cardGap)
    }

    /// The browsed row's card: rebuilt only when the browsed row or what is known of it changes.
    private func fillCard() {
        guard let browsed = state.browsed, rows.indices.contains(browsed) else { return }
        let row = rows[browsed]
        // The name is the strip's, under the picture; the card has what follows it.
        var lines: [String] = []
        if let url = row.url {
            let info = fileInfo[url]
            lines += PlaylistRowFacts(facts: facts[url], resume: info?.resume, size: info?.size, date: info?.date).card
        } else if let subtitle = row.subtitle {
            lines.append(subtitle)
        }
        card.fill(lines: lines)
    }

    // MARK: Scrolling

    private var now: Double { ProcessInfo.processInfo.systemUptime }

    private func scrolled(_ event: NSEvent) {
        guard let browsed = state.browsed else { return }
        guard event.hasPreciseScrollingDeltas else {   // a wheel: a row a notch
            if event.scrollingDeltaY != 0 { step(by: event.scrollingDeltaY > 0 ? -1 : 1) }
            return
        }
        let outcome = scroll.event(fingerDelta: Double(event.scrollingDeltaY), crossDelta: Double(event.scrollingDeltaX),
                                   phase: ScrollPhase(rawValue: event.phase.rawValue),
                                   momentum: ScrollPhase(rawValue: event.momentumPhase.rawValue),
                                   layout: strip.layout, current: browsed, now: event.timestamp)
        apply(outcome)
        if scroll.isMoving {
            restTimer?.invalidate()
            restTimer = Timer.scheduledTimer(withTimeInterval: FilmstripScroll.restDelay, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.rested() }
            }
        }
    }

    /// A press on the rows stops a glide at once: the strip rests on the row nearest the centre, then the click or drag
    /// goes on from there.
    private func pressBegan() {
        guard scroll.isMoving else { return }
        _ = scroll.end()
        settle()
    }

    private func dragged(by dy: CGFloat) {
        guard let browsed = state.browsed else { return }
        apply(scroll.drag(by: Double(dy), layout: strip.layout, current: browsed))
    }

    private func apply(_ outcome: FilmstripScroll.Outcome) {
        if let row = outcome.item { state.browse(to: row, now: now, inGesture: true) }
        returnTimer?.invalidate()
        place(animated: false)
        if outcome.commit { settle() }
    }

    private func rested() {
        if scroll.rested(now: now) { settle() }
    }

    /// The strip comes to rest on the row nearest the centre; that row is browsed, nothing opens.
    private func settle() {
        restTimer?.invalidate()
        restTimer = nil
        if let settled = scroll.settled(layout: strip.layout) { state.browse(to: settled.item, now: now, inGesture: false) }
        scroll.settle()
        refreshState()
        place(animated: true)
    }

    // MARK: Going back

    private func refreshState() {
        state.activity(now: now, inGesture: scroll.isMoving)
        // The pointer over the strip only puts the return off; the strip still follows the playing video.
        if pointerInside {
            returnTimer?.invalidate()
            returnTimer = nil
        } else {
            armReturn()
        }
    }

    private func armReturn() {
        returnTimer?.invalidate()
        returnTimer = nil
        guard let deadline = state.returnDeadline, isShownOnScreen else { return }
        returnTimer = Timer.scheduledTimer(withTimeInterval: max(0, deadline - now), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.returnFired() }
        }
    }

    private func returnFired() {
        returnTimer = nil
        guard !pointerInside else { return }   // leaving the strip arms it again
        guard state.fire(now: now + 0.001) else { return }
        scroll.settle()
        place(animated: true)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        pointerInside = true
        refreshState()
    }

    override func mouseExited(with event: NSEvent) {
        pointerInside = false
        refreshState()
    }

    // MARK: Visibility: quiet when not seen

    private var isShownOnScreen: Bool {
        guard let window, !isHiddenOrHasHiddenAncestor else { return false }
        return window.occlusionState.contains(.visible)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        if let window {
            NotificationCenter.default.addObserver(self, selector: #selector(occlusionChanged),
                                                   name: NSWindow.didChangeOcclusionStateNotification, object: window)
        }
        shownChanged()
    }

    override func viewDidHide() {
        super.viewDidHide()
        shownChanged()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        shownChanged()
    }

    @objc private func occlusionChanged() { shownChanged() }

    private func shownChanged() {
        guard isShownOnScreen else {
            restTimer?.invalidate()
            restTimer = nil
            returnTimer?.invalidate()
            returnTimer = nil
            dwellTimer?.invalidate()
            dwellTimer = nil
            reading?.cancel()
            reading = nil
            posters.stop()
            state.cancel()
            dwell.reset()
            asked = []
            readTimer?.invalidate()
            readTimer = nil
            // A gesture cut short by the hiding: the strip sits on the browsed row again.
            _ = scroll.end()
            scroll.settle()
            place(animated: false)
            return
        }
        visibleChanged()
        refreshState()
    }

    // MARK: Pictures and facts for the rows in view

    private func visibleChanged() {
        guard isShownOnScreen else { return }
        refreshVisibleText()
        scheduleRead()
        checkDwell()
    }

    /// The rows in view are read once the strip has rested `readDelay`: rows a flick carries past are not read.
    private func scheduleRead() {
        readTimer?.invalidate()
        readTimer = Timer.scheduledTimer(withTimeInterval: Self.readDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.readTimer = nil
                self?.readVisible()
            }
        }
    }

    private func refreshVisibleText() {
        for item in strip.visibleItems where rows.indices.contains(item) {
            let row = rows[item]
            let detail: String, progress: Double?
            if let url = row.url {
                let info = fileInfo[url]
                let rowFacts = PlaylistRowFacts(facts: facts[url], resume: info?.resume, size: info?.size, date: info?.date)
                detail = rowFacts.detail
                progress = rowFacts.progress
            } else {
                detail = row.subtitle ?? ""
                progress = nil
            }
            strip.setRow(item, title: Self.title(row), detail: detail, progress: progress)
        }
        if let browsed = state.browsed, strip.visibleItems.contains(browsed) { fillCard() }
    }

    /// The rows in view not looked at yet: their kept pictures, sizes, dates and positions, read off the main thread.
    private func readVisible() {
        let urls = strip.visibleItems.compactMap { rows.indices.contains($0) ? rows[$0].url : nil }.filter { !looked.contains($0) }
        guard !urls.isEmpty else { return }
        reading?.cancel()
        let lastFrames = lastFrames, posterStore = posters.store
        reading = Task { @MainActor [weak self] in
            let resume = ResumeStore()
            for url in urls {
                let found = await Task.detached(priority: .utility) { () -> (CGImage?, FileInfo, FileFacts?) in
                    let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                    let size = values?.fileSize.map(Int64.init)
                    let image = lastFrames.image(for: url) ?? posterStore.image(for: url)
                    return (image, FileInfo(size: size, date: values?.contentModificationDate,
                                            resume: resume.entry(for: url, size: size)), FileFactsStore.shared.facts(for: [url])[url.path])
                }.value
                guard let self, !Task.isCancelled else { return }
                self.looked.insert(url)
                self.fileInfo[url] = found.1
                self.facts[url] = found.2
                if let image = found.0 { self.picture(image, for: url) }
            }
            self?.refreshVisibleText()
            self?.checkDwell()
        }
    }

    private func picture(_ image: CGImage, for url: URL) {
        hasPicture.insert(url)
        for (index, row) in rows.enumerated() where row.url == url { strip.setImage(image, forItem: index) }
    }

    private func learned(_ found: FileFacts, for url: URL) {
        let had = facts[url]
        facts[url] = found
        if had?.width != found.width || had?.height != found.height { relayoutSoon() }
        refreshVisibleText()
    }

    /// Rows in view that were looked at and lack a picture or facts: a poster (or a probe, when the picture is kept)
    /// once they have stayed `PosterDwell.delay`.
    private func checkDwell() {
        dwellTimer?.invalidate()
        dwellTimer = nil
        guard isShownOnScreen else { return }
        let candidates: [URL?] = strip.visibleItems.map { item in
            guard rows.indices.contains(item), let url = rows[item].url, looked.contains(url),
                  !hasPicture.contains(url) || facts[url] == nil,
                  Playlist.videoExtensions.contains(url.pathExtension.lowercased()) else { return nil }
            return url
        }
        let inView = candidates.compactMap { $0 }
        // What the queue makes is only what is in view now: rows that left are dropped from it.
        posters.retain(Set(inView))
        let due = dwell.visible(candidates, now: now)
        if !due.isEmpty {
            // With the files asked before and still missing: a new ask cancels the last one's reading.
            asked.formUnion(due)
            let wanted = inView.filter { asked.contains($0) }.prefix(PosterDwell.cap)
            posters.want(wanted.map(\.path))
        }
        if let deadline = dwell.nextDeadline {
            dwellTimer = Timer.scheduledTimer(withTimeInterval: max(0.01, deadline - now), repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.checkDwell() }
            }
        }
    }
}

/// The browsed row's card, under its name: a line each of what is known; a click opens the row.
@MainActor final class PlaylistCardView: NSView {
    var onPress: (() -> Void)?
    private let stack = NSStackView()
    private var lines: [String] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            // A label draws its text 2 pt in from its frame: the lines start on the caption's edge.
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: -2), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func fill(lines: [String]) {
        guard lines != self.lines else { return }
        self.lines = lines
        for view in stack.arrangedSubviews { view.removeFromSuperview() }
        for line in lines {
            let field = NSTextField(wrappingLabelWithString: line)
            field.isSelectable = false   // a click opens the row; the keyboard stays with the video
            field.maximumNumberOfLines = 1
            field.lineBreakMode = .byTruncatingTail
            field.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .regular)
            field.textColor = Chrome.Palette.overMedia.secondaryText
            field.preferredMaxLayoutWidth = max(0, bounds.width)
            stack.addArrangedSubview(field)
        }
    }

    func fittingHeight(width: CGFloat) -> CGFloat {
        for case let field as NSTextField in stack.arrangedSubviews { field.preferredMaxLayoutWidth = width }
        return stack.fittingSize.height + 20
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        for case let field as NSTextField in stack.arrangedSubviews { field.preferredMaxLayoutWidth = newSize.width }
    }

    /// Where a press began, in window coordinates: a press that moved is not a click.
    private var pressStart: NSPoint?

    /// The card takes its clicks itself: none reaches its labels.
    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }

    override func mouseDown(with event: NSEvent) { pressStart = event.locationInWindow }

    override func mouseUp(with event: NSEvent) {
        defer { pressStart = nil }
        guard let start = pressStart else { return }
        let end = event.locationInWindow
        if hypot(end.x - start.x, end.y - start.y) < 3 { onPress?() }
    }
}
