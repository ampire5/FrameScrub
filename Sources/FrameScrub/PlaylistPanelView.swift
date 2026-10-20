import AppKit
import FrameScrubCore

/// The folder's videos, current one highlighted; a click opens a file. On top: a name filter and the order.
final class PlaylistPanelView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    var onSelect: ((URL) -> Void)?
    /// The filter text changed (live, as it is typed).
    var onFilter: ((String) -> Void)?
    /// The order picked from the menu.
    var onSort: ((PlaylistSort) -> Void)?
    /// Return in the filter field: open the first file shown.
    var onSubmitFilter: (() -> Void)?
    /// Esc in the filter field (after clearing it): the keys go back to the player.
    var onEndFilter: (() -> Void)?
    private let search = NSSearchField()
    private let sortButton = NSPopUpButton(frame: .zero, pullsDown: false)
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private var files: [URL] = []
    /// `playlist-font-size`; the rows grow with it.
    var fontSize: CGFloat = 14 {
        didSet {
            guard fontSize != oldValue else { return }
            table.rowHeight = (fontSize * 1.8).rounded()
            table.reloadData()
            if files.indices.contains(table.selectedRow) { table.scrollRowToVisible(table.selectedRow) }
        }
    }
    private var updating = false
    private static let widthKey = "PlaylistWidth"   // window state, not a setting
    private lazy var width = widthAnchor.constraint(equalToConstant: {
        let saved = UserDefaults.standard.double(forKey: Self.widthKey)
        return saved > 0 ? saved : 260
    }())

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        // The table refuses first responder, so the selected row is drawn unemphasized (light gray in a light
        // appearance), which would make the white labels unreadable. A dark appearance (inherited by the table
        // and scroll view) keeps the selection colours consistent with the dark overlay.
        appearance = NSAppearance(named: .darkAqua)
        layer?.backgroundColor = NSColor(white: 0, alpha: 0.7).cgColor
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.backgroundColor = .clear
        table.rowHeight = (fontSize * 1.8).rounded()
        table.style = .plain
        table.intercellSpacing = .zero   // rows touch: the stripes and the selection fill the whole row
        table.refusesFirstResponder = true   // clicks still select, but keys keep going to the video view
        table.dataSource = self
        table.delegate = self
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        search.placeholderString = "Filter (⌘F)"
        search.controlSize = .small
        search.sendsSearchStringImmediately = true
        search.delegate = self
        search.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(alignNames), name: NSView.frameDidChangeNotification, object: search)
        search.target = self
        search.action = #selector(filterChanged)
        for sort in PlaylistSort.allCases {
            sortButton.addItem(withTitle: sort.shortTitle)
            sortButton.lastItem?.representedObject = sort.rawValue
        }
        sortButton.controlSize = .small
        sortButton.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        sortButton.target = self
        sortButton.action = #selector(sortPicked)
        let bar = NSStackView(views: [search, sortButton])
        bar.spacing = 6
        bar.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 6, right: 8)
        sortButton.setContentHuggingPriority(.required, for: .horizontal)
        search.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        bar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bar)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: leadingAnchor), bar.trailingAnchor.constraint(equalTo: trailingAnchor),
            bar.topAnchor.constraint(equalTo: topAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: bar.bottomAnchor), scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        let grip = ResizeGripView()
        grip.translatesAutoresizingMaskIntoConstraints = false
        addSubview(grip)   // above the scroll view: the left edge drags the width
        NSLayoutConstraint.activate([
            grip.leadingAnchor.constraint(equalTo: leadingAnchor), grip.widthAnchor.constraint(equalToConstant: 6),
            grip.topAnchor.constraint(equalTo: topAnchor), grip.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        grip.onDrag = { [weak self] dx in self?.resize(by: dx) }
        grip.onEnd = { [weak self] in
            guard let self else { return }
            UserDefaults.standard.set(Double(width.constant), forKey: Self.widthKey)
        }
        width.isActive = true
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? {
        alphaValue > 0.01 ? super.hitTest(point) : nil   // faded out: clicks reach the video
    }

    /// Where the names start in a row: under the filter field's text, so one text edge runs down the panel.
    private var nameInset: CGFloat = 30

    /// Follows the filter field: its frame is only known once the bar above the list has been laid out.
    @objc private func alignNames() {
        guard search.frame.width > 0, let cell = search.cell as? NSSearchFieldCell else { return }
        let textX = search.convert(cell.searchTextRect(forBounds: search.bounds), to: self).minX
        let columnX = table.convert(table.rect(ofColumn: 0), to: self).minX
        let inset = (textX - columnX + 2).rounded()   // + the field editor's own text padding
        guard inset > 0, inset != nameInset else { return }
        nameInset = inset
        table.enumerateAvailableRowViews { row, _ in
            for case let cell as NSTableCellView in row.subviews {
                cell.constraints.first { $0.identifier == "leading" }?.constant = inset
            }
        }
    }

    private func resize(by dx: CGFloat) {
        let limit = max(160, (superview?.bounds.width ?? 800) - 80)
        width.constant = min(max(width.constant - dx, 160), limit)   // the panel is pinned on the right: dragging left widens
    }

    /// Whether the filter field has the keyboard (the panel stays while it does).
    var isEditingFilter: Bool {
        guard let editor = window?.firstResponder as? NSText else { return false }
        return editor.delegate === search
    }

    func beginFilter() {
        window?.makeFirstResponder(search)
    }

    func showSort(_ sort: PlaylistSort) {
        sortButton.selectItem(at: PlaylistSort.allCases.firstIndex(of: sort) ?? 0)
    }

    @objc private func filterChanged() { onFilter?(search.stringValue) }

    @objc private func sortPicked() {
        guard let raw = sortButton.selectedItem?.representedObject as? String, let sort = PlaylistSort(rawValue: raw) else { return }
        onSort?(sort)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            onSubmitFilter?()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            if !search.stringValue.isEmpty {
                search.stringValue = ""
                filterChanged()
            }
            onEndFilter?()
            return true
        default:
            return false
        }
    }

    func update(files: [URL], current: Int) {
        updating = true
        defer { updating = false }
        if files != self.files {   // unchanged list: only move the selection, no reload inside the table's own callback
            self.files = files
            table.reloadData()
        }
        guard files.indices.contains(current) else { return }
        table.selectRowIndexes([current], byExtendingSelection: false)
        table.scrollRowToVisible(current)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { files.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? {
            let cell = NSTableCellView()
            cell.identifier = id
            let field = NSTextField(labelWithString: "")
            field.lineBreakMode = .byTruncatingMiddle
            field.textColor = .white
            field.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(field)
            cell.textField = field
            let baseline = field.firstBaselineAnchor.constraint(equalTo: cell.centerYAnchor)
            baseline.identifier = "baseline"
            let leading = field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: nameInset)
            leading.identifier = "leading"
            NSLayoutConstraint.activate([
                leading,
                field.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -8),
                baseline,
            ])
            return cell
        }()
        let font = NSFont.systemFont(ofSize: fontSize)
        cell.textField?.font = font
        // Optical centring: the middle of the capitals on the row's middle (centring the field would count the
        // room for descenders and sit the names low).
        cell.constraints.first { $0.identifier == "baseline" }?.constant = (font.capHeight / 2).rounded()
        cell.constraints.first { $0.identifier == "leading" }?.constant = nameInset
        cell.textField?.stringValue = files[row].lastPathComponent
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let id = NSUserInterfaceItemIdentifier("row")
        let view = (tableView.makeView(withIdentifier: id, owner: self) as? StripedRowView) ?? StripedRowView()
        view.identifier = id
        view.isOdd = row % 2 == 1
        return view
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !updating, files.indices.contains(table.selectedRow) else { return }
        onSelect?(files[table.selectedRow])
    }
}

/// Click-through area that reports the pointer entering (true) and leaving (false) it: the playlist's hover area.
/// The parts `excludes` names (window points) do not count as in it: moving onto one is leaving, moving off it into
/// the rest is entering.
final class HoverZoneView: NSView {
    var onHover: ((Bool) -> Void)?
    var excludes: ((NSPoint) -> Bool)?
    private var hovered = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeInActiveApp,
                                                              .inVisibleRect],
                                       owner: self))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func mouseEntered(with event: NSEvent) { setHovered(!(excludes?(event.locationInWindow) ?? false)) }
    override func mouseMoved(with event: NSEvent) { setHovered(!(excludes?(event.locationInWindow) ?? false)) }
    override func mouseExited(with event: NSEvent) { setHovered(false) }

    private func setHovered(_ inside: Bool) {
        guard inside != hovered else { return }
        hovered = inside
        onHover?(inside)
    }
}

/// The playlist's left edge: a resize cursor, and horizontal drags reported as deltas.
private final class ResizeGripView: NSView {
    var onDrag: ((CGFloat) -> Void)?
    var onEnd: (() -> Void)?
    private var lastX: CGFloat?

    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    // Handled here, not passed up the responder chain: otherwise AppKit does not send this view the drags.
    override func mouseDown(with event: NSEvent) { lastX = event.locationInWindow.x }
    override func mouseDragged(with event: NSEvent) {
        let x = event.locationInWindow.x
        if let lastX { onDrag?(x - lastX) }
        lastX = x
    }
    override func mouseUp(with event: NSEvent) {
        lastX = nil
        onEnd?()
    }
}

/// A playlist row: every other one slightly lighter, so long lists are easy to follow across.
private final class StripedRowView: NSTableRowView {
    var isOdd = false { didSet { needsDisplay = true } }

    override func drawBackground(in dirtyRect: NSRect) {
        guard isOdd else { return }
        NSColor(white: 1, alpha: 0.05).setFill()
        bounds.fill()
    }
}
