import AppKit
import FrameScrubCore
import HomeScreenModel
import SlotChrome

/// The playlist (shown in a slot): the folder's videos or a page's list, current one highlighted; a click opens a row.
/// Its filter and, for a folder, its order are tools in the slot's capsule (`tools`); the capsule's filter field drives
/// the filter here (`filterEdited`, `filterCommand`, `filterEnded`).
final class PlaylistPanelView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    /// A row was clicked: its index among the rows shown.
    var onSelect: ((Int) -> Void)?
    /// The filter text changed (live, as it is typed).
    var onFilter: ((String) -> Void)?
    /// The order picked from the menu.
    var onSort: ((PlaylistSort) -> Void)?
    /// Return in the filter field: open the first file shown.
    var onSubmitFilter: (() -> Void)?
    /// Esc in the filter field (after clearing it): the keys go back to the player.
    var onEndFilter: (() -> Void)?
    /// 🔍 or ⌘F: the slot opens its capsule's filter field (with `filterText`).
    var onBeginFilter: (() -> Void)?
    /// The tools changed (the filter's accent, the order).
    var onToolsChanged: (() -> Void)?
    /// Whether the capsule's filter field has the keyboard (set by the slots).
    var editingFilter: (() -> Bool)?
    /// The filter's text, kept while the field is closed.
    private(set) var filterText = ""
    /// The folder's order; nil for a page's list, which keeps the page's order.
    private var sort: BrowserSort?
    private var listName: String?
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private var rows: [PlaylistRow] = []
    /// `playlist-font-size`; the rows grow with it.
    var fontSize: CGFloat = 14 {
        didSet {
            guard fontSize != oldValue else { return }
            table.rowHeight = (fontSize * 1.8).rounded()
            table.reloadData()
            if rows.indices.contains(table.selectedRow) { table.scrollRowToVisible(table.selectedRow) }
        }
    }
    private var updating = false
    /// `playlist-view`: the table, or the strip (made the first time it is asked for).
    var mode = PlaylistView.list {
        didSet { if mode != oldValue { applyMode() } }
    }
    /// `playlist-strip-return`.
    var stripReturn: Double = 3 {
        didSet { strip?.returnDelay = stripReturn }
    }
    private var strip: PlaylistStripView?
    private var current = -1
    /// The rows last given, whichever view shows them.
    private var latest: [PlaylistRow] = []

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        // The table refuses first responder, so the selected row is drawn unemphasized (light gray in a light
        // appearance), which would make the white labels unreadable. A dark appearance (inherited by the table
        // and scroll view) keeps the selection colours consistent with the dark overlay.
        appearance = NSAppearance(named: .darkAqua)   // the slot draws the backdrop
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
        // The first row starts under the slot's capsule, which lies over the list.
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: PluginPanel.topInset, left: 0, bottom: 0, right: 0)
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor), scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Where the names start in a row.
    private let nameInset: CGFloat = 14

    /// The strip instead of the table, or back.
    private func applyMode() {
        if mode == .strip, strip == nil {
            let strip = PlaylistStripView()
            strip.returnDelay = stripReturn
            strip.onSelect = { [weak self] row in self?.onSelect?(row) }
            strip.translatesAutoresizingMaskIntoConstraints = false
            addSubview(strip)
            NSLayoutConstraint.activate([
                strip.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
                strip.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
                strip.topAnchor.constraint(equalTo: scroll.topAnchor), strip.bottomAnchor.constraint(equalTo: scroll.bottomAnchor),
            ])
            self.strip = strip
        }
        strip?.isHidden = mode != .strip
        scroll.isHidden = mode == .strip
        if mode == .strip { strip?.update(rows: latest, current: current) } else { updateTable() }
    }

    /// Whether the filter field has the keyboard (the panel stays while it does).
    var isEditingFilter: Bool { editingFilter?() ?? false }

    func beginFilter() { onBeginFilter?() }

    /// 🔍 (accented while the filter holds text) and, for a folder, ⇅ with the orders, the chosen one ticked.
    var tools: [SlotTool] {
        let tip = filterText.isEmpty ? (listName.map { "Filter \($0) (⌘F)" } ?? "Filter (⌘F)") : "Filter: \(filterText)"
        var tools = [SlotTool(id: "filter", symbol: "magnifyingglass", accent: !filterText.isEmpty, tip: tip,
                              action: { [weak self] in self?.beginFilter() })]
        if let sort {
            tools.append(SlotTool(id: "order", symbol: "arrow.up.arrow.down", tip: "Order: \(Self.title(sort))",
                                  menu: { [weak self] in self?.sortMenu(sort) ?? NSMenu() }))
        }
        return tools
    }

    private func sortMenu(_ sort: BrowserSort) -> NSMenu {
        let menu = NSMenu()
        for key in PlaylistSort.allCases {
            let chosen = key.rawValue == sort.key.rawValue
            let item = menu.addItem(withTitle: chosen ? Self.title(sort) : key.shortTitle,
                                    action: #selector(sortPicked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = key.rawValue
            item.state = chosen ? .on : .off
        }
        return menu
    }

    /// A folder: its order (Home's too) can be picked; the chosen field shows its direction, picking it again turns it.
    func showSort(_ sort: BrowserSort) {
        self.sort = sort
        listName = nil
        onToolsChanged?()
    }

    private static func title(_ sort: BrowserSort) -> String {
        switch sort.key {
        case .name: sort.ascending ? "Name" : "Name Z–A"
        case .date: sort.ascending ? "Oldest" : "Newest"
        case .size: sort.ascending ? "Smallest" : "Largest"
        }
    }

    /// A page's list: kept in the page's order; `name` (if the page gave one) shows in the filter's tip.
    func showList(name: String?) {
        sort = nil
        listName = name
        onToolsChanged?()
    }

    /// The capsule's field changed.
    func filterEdited(_ text: String) {
        let accentChanged = text.isEmpty != filterText.isEmpty
        filterText = text
        onFilter?(text)
        strip?.filterEdited()
        if accentChanged { onToolsChanged?() }
    }

    /// The capsule's field closed: the keys go back to the player.
    func filterEnded() {
        strip?.filterEdited()
        onToolsChanged?()
        onEndFilter?()
    }

    @objc private func sortPicked(_ item: NSMenuItem) {
        guard let raw = item.representedObject as? String, let sort = PlaylistSort(rawValue: raw) else { return }
        onSort?(sort)
    }

    /// Keys in the capsule's filter field: ↩ opens (the browsed row in the strip, else the first file shown), ↑ ↓ and the
    /// page keys browse the strip. False for keys the field keeps.
    func filterCommand(_ selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            if let strip, mode == .strip, !strip.browsedIsPlaying { strip.openBrowsed() } else { onSubmitFilter?() }
            return true
        case #selector(NSResponder.moveUp(_:)) where mode == .strip:
            strip?.step(by: -1)
            return true
        case #selector(NSResponder.moveDown(_:)) where mode == .strip:
            strip?.step(by: 1)
            return true
        case #selector(NSResponder.scrollPageUp(_:)) where mode == .strip,
             #selector(NSResponder.pageUp(_:)) where mode == .strip:
            strip.map { $0.step(by: -$0.pageRows) }
            return true
        case #selector(NSResponder.scrollPageDown(_:)) where mode == .strip,
             #selector(NSResponder.pageDown(_:)) where mode == .strip:
            strip.map { $0.step(by: $0.pageRows) }
            return true
        default:
            return false
        }
    }

    /// `current`: the row of the item playing; -1 when it is not shown.
    func update(rows: [PlaylistRow], current: Int) {
        latest = rows
        self.current = current
        // Only the one shown is kept up to date; the other catches up when it is shown (`applyMode`).
        if mode == .strip {
            strip?.update(rows: rows, current: current)
        } else {
            updateTable()
        }
    }

    private func updateTable() {
        let rows = latest
        updating = true
        defer { updating = false }
        if rows != self.rows {   // unchanged list: only move the selection, no reload inside the table's own callback
            self.rows = rows
            table.reloadData()
        }
        guard rows.indices.contains(current) else { table.deselectAll(nil); return }
        table.selectRowIndexes([current], byExtendingSelection: false)
        table.scrollRowToVisible(current)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

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
        cell.textField?.stringValue = rows[row].title
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
        guard !updating, rows.indices.contains(table.selectedRow) else { return }
        onSelect?(table.selectedRow)
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
