import AppKit

/// The style buttons of Subject Focus's panel, three to a row: the standard styles, Custom, then the user's presets,
/// each of these with a faint × in its corner (theirs, and it deletes them; a right click also replaces one with the
/// look on screen), and "+" last, which asks for a name in place (Return saves, Esc gives up). Under them: Hide
/// Standard Presets. Rebuilt only when the list changes; a change of selection only sets the buttons' states.
@MainActor final class PresetRowView: NSView, NSTextFieldDelegate {
    struct Item: Equatable {
        let id: String
        let title: String
        let user: Bool
    }

    var onPick: (String) -> Void = { _ in }
    var onDelete: (String) -> Void = { _ in }
    var onReplace: (String) -> Void = { _ in }
    var onSave: (String) -> Void = { _ in }
    var onHideStandard: (Bool) -> Void = { _ in }
    /// The name "+" offers.
    var suggestedName: () -> String = { "Preset" }

    private static let secondary = NSColor(srgbRed: 0x9a / 255, green: 0x9a / 255, blue: 0xa2 / 255, alpha: 1)
    private static let buttonWidth: CGFloat = 96
    private let stack = NSStackView()
    private var grid = NSGridView(numberOfColumns: 3, rows: 0)
    private let nameRow = NSStackView()
    private let nameField = NSTextField()
    private let hideStandard = NSButton(checkboxWithTitle: "Hide standard presets", target: nil, action: nil)
    private var items: [Item] = []
    private var buttons: [String: NSButton] = [:]
    private var chips: [String: PresetChip] = [:]

    init() {
        super.init(frame: .zero)
        nameField.placeholderString = "Preset name"
        nameField.delegate = self
        nameField.controlSize = .small
        nameField.font = .systemFont(ofSize: 12)
        let save = NSButton(title: "Save", target: self, action: #selector(saveName))
        save.bezelStyle = .push
        save.controlSize = .small
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelName))
        cancel.bezelStyle = .push
        cancel.controlSize = .small
        nameRow.setViews([nameField, save, cancel], in: .leading)
        nameRow.spacing = 6
        nameRow.isHidden = true
        hideStandard.controlSize = .small
        hideStandard.font = .systemFont(ofSize: 11)
        hideStandard.contentTintColor = Self.secondary
        hideStandard.target = self
        hideStandard.action = #selector(toggleHideStandard)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setViews([nameRow, hideStandard], in: .top)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            nameRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Shows `items` (rebuilt only when they changed) with `selected` lit.
    func update(_ items: [Item], selected: String?, hideStandard hidden: Bool) {
        if items != self.items {
            self.items = items
            rebuild()
        }
        for (id, b) in buttons { b.state = id == selected ? .on : .off }
        for (id, c) in chips { c.isSelected = id == selected }
        hideStandard.state = hidden ? .on : .off
    }

    /// A new grid each time: removing a grid's rows leaves their views in it, drawn over the new ones.
    private func rebuild() {
        grid.removeFromSuperview()
        grid = NSGridView(numberOfColumns: 3, rows: 0)
        grid.columnSpacing = 6
        grid.rowSpacing = 6
        buttons = [:]
        chips = [:]
        var cells: [NSView] = items.map(cell)
        let plus = NSButton(title: "+", target: self, action: #selector(askName))
        plus.bezelStyle = .push
        plus.toolTip = "Save the look on screen as a preset"
        plus.translatesAutoresizingMaskIntoConstraints = false
        plus.widthAnchor.constraint(equalToConstant: Self.buttonWidth).isActive = true
        cells.append(plus)
        // three columns; a preset whose name does not fit one takes two (or three) of them, starting a row if it must
        var rows: [[(NSView, Int)]] = [[]]
        for view in cells {
            let span = (view as? PresetChip)?.span ?? 1
            if rows[rows.count - 1].reduce(0, { $0 + $1.1 }) + span > 3 { rows.append([]) }
            rows[rows.count - 1].append((view, span))
        }
        for row in rows {
            var views: [NSView] = []
            var merges: [Range<Int>] = []
            for (view, span) in row {
                if span > 1 { merges.append(views.count..<views.count + span) }
                views.append(view)
                for _ in 1..<max(span, 1) { views.append(NSGridCell.emptyContentView) }
            }
            while views.count < 3 { views.append(NSGridCell.emptyContentView) }
            grid.addRow(with: views)
            for range in merges { grid.mergeCells(inHorizontalRange: NSRange(range), verticalRange: NSRange(location: grid.numberOfRows - 1, length: 1)) }
        }
        stack.insertArrangedSubview(grid, at: 0)
    }

    /// A standard style's push button, or the user's preset as one block (`PresetChip`).
    private func cell(_ item: Item) -> NSView {
        guard item.user else { return button(item) }
        let chip = PresetChip(title: item.title, cell: Self.buttonWidth, gap: 6)
        chip.onPick = { [weak self] in self?.onPick(item.id) }
        chip.onDelete = { [weak self] in self?.onDelete(item.id) }
        chip.toolTip = "Your preset: × deletes it (click twice), a right click replaces it with the look on screen"
        chip.menu = menu(for: item)
        chips[item.id] = chip
        return chip
    }

    private func button(_ item: Item) -> NSButton {
        let b = NSButton(title: item.title, target: self, action: #selector(pick(_:)))
        b.setButtonType(.pushOnPushOff)
        b.bezelStyle = .push
        b.lineBreakMode = .byTruncatingTail
        b.identifier = NSUserInterfaceItemIdentifier(item.id)
        b.translatesAutoresizingMaskIntoConstraints = false
        b.widthAnchor.constraint(equalToConstant: Self.buttonWidth).isActive = true
        buttons[item.id] = b
        return b
    }

    private func menu(for item: Item) -> NSMenu {
        let menu = NSMenu()
        let replace = menu.addItem(withTitle: "Replace with the Look on Screen", action: #selector(replace(_:)), keyEquivalent: "")
        replace.target = self
        replace.representedObject = item.id
        let delete = menu.addItem(withTitle: "Delete “\(item.title)”", action: #selector(deleteItem(_:)), keyEquivalent: "")
        delete.target = self
        delete.representedObject = item.id
        return menu
    }

    @objc private func pick(_ sender: NSButton) { sender.identifier.map { onPick($0.rawValue) } }
    @objc private func deleteItem(_ sender: NSMenuItem) { (sender.representedObject as? String).map(onDelete) }
    @objc private func replace(_ sender: NSMenuItem) { (sender.representedObject as? String).map(onReplace) }
    @objc private func toggleHideStandard() { onHideStandard(hideStandard.state == .on) }

    @objc private func askName() {
        nameField.stringValue = suggestedName()
        nameRow.isHidden = false
        window?.makeFirstResponder(nameField)
        nameField.currentEditor()?.selectAll(nil)
    }

    @objc private func saveName() {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        nameRow.isHidden = true
        window?.makeFirstResponder(nil)
        guard !name.isEmpty else { return }
        onSave(name)
    }

    @objc private func cancelName() {
        nameRow.isHidden = true
        window?.makeFirstResponder(nil)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)): saveName(); return true
        case #selector(NSResponder.cancelOperation(_:)): cancelName(); return true
        default: return false
        }
    }
}

/// A user's preset as one block, the way browser tabs carry their close button: the name, a hairline, and a faint ×
/// inside the same rounded shape (the × is also what tells it from the standard styles). Hovering brightens the ×; a
/// click on it arms it (a red trash for 3 s), a second click deletes. A click anywhere else picks the preset.
@MainActor final class PresetChip: NSView {
    var onPick: () -> Void = {}
    var onDelete: () -> Void = {}
    var isSelected = false { didSet { updateLook() } }

    private let label: NSTextField
    private let divider = NSView()
    private let close = NSImageView()
    private var hover = false, overClose = false, armed = false
    private var disarm: DispatchWorkItem?
    private static let closeWidth: CGFloat = 18

    /// How many of the row's columns it takes: its name whole, up to three.
    let span: Int

    init(title: String, cell: CGFloat, gap: CGFloat) {
        label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12)
        let needed = label.fittingSize.width + 4 + 2 + 1 + Self.closeWidth + 6
        span = min(3, Int(((needed + gap) / (cell + gap)).rounded(.up)))
        let width = CGFloat(span) * cell + CGFloat(span - 1) * gap
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.cornerCurve = .continuous
        label.font = .systemFont(ofSize: 12)
        label.lineBreakMode = .byTruncatingTail
        label.alignment = .center
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        divider.wantsLayer = true
        close.imageScaling = .scaleNone
        for view in [label, divider, close] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: width), heightAnchor.constraint(equalToConstant: 24),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: divider.leadingAnchor, constant: -2),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            divider.trailingAnchor.constraint(equalTo: close.leadingAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),
            divider.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            divider.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
            close.trailingAnchor.constraint(equalTo: trailingAnchor),
            close.widthAnchor.constraint(equalToConstant: Self.closeWidth),
            close.topAnchor.constraint(equalTo: topAnchor), close.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
        updateLook()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeInActiveApp,
                                                                .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hover = true; track(event) }
    override func mouseMoved(with event: NSEvent) { track(event) }
    override func mouseExited(with event: NSEvent) { hover = false; overClose = false; updateLook() }

    private func track(_ event: NSEvent) {
        overClose = convert(event.locationInWindow, from: nil).x >= bounds.maxX - Self.closeWidth
        updateLook()
    }

    override func mouseDown(with event: NSEvent) {
        guard convert(event.locationInWindow, from: nil).x >= bounds.maxX - Self.closeWidth else {
            setArmed(false)
            onPick()
            return
        }
        if armed { onDelete() } else { setArmed(true) }
    }

    private func setArmed(_ on: Bool) {
        armed = on
        disarm?.cancel()
        if on {
            let work = DispatchWorkItem { [weak self] in self?.setArmed(false) }
            disarm = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
        }
        setAccessibilityHelp(on ? "Click × again to delete" : nil)
        updateLook()
    }

    private func updateLook() {
        let base: NSColor = isSelected ? .controlAccentColor : NSColor(white: 1, alpha: hover ? 0.17 : 0.12)
        layer?.backgroundColor = base.cgColor
        label.textColor = .white
        divider.layer?.backgroundColor = NSColor(white: 1, alpha: isSelected ? 0.35 : 0.15).cgColor
        let symbol = armed ? "trash.fill" : "xmark"
        close.image = NSImage(systemSymbolName: symbol, accessibilityDescription: armed ? "Delete" : "Delete…")?
            .withSymbolConfiguration(.init(pointSize: armed ? 10 : 9, weight: .semibold))
        close.contentTintColor = armed ? .systemRed
            : NSColor(white: 1, alpha: overClose ? 0.95 : (hover || isSelected ? 0.6 : 0.4))
        close.toolTip = armed ? "Click again to delete" : "Delete"
    }
}
