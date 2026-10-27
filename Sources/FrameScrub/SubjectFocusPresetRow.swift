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
    private let grid = NSGridView(numberOfColumns: 3, rows: 0)
    private let nameRow = NSStackView()
    private let nameField = NSTextField()
    private let hideStandard = NSButton(checkboxWithTitle: "Hide standard presets", target: nil, action: nil)
    private var items: [Item] = []
    private var buttons: [String: NSButton] = [:]

    init() {
        super.init(frame: .zero)
        grid.columnSpacing = 6
        grid.rowSpacing = 6
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
        stack.setViews([grid, nameRow, hideStandard], in: .top)
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
        hideStandard.state = hidden ? .on : .off
    }

    private func rebuild() {
        while grid.numberOfRows > 0 { grid.removeRow(at: 0) }
        buttons = [:]
        var cells: [NSView] = items.map(cell)
        let plus = NSButton(title: "+", target: self, action: #selector(askName))
        plus.bezelStyle = .push
        plus.toolTip = "Save the look on screen as a preset"
        plus.translatesAutoresizingMaskIntoConstraints = false
        plus.widthAnchor.constraint(equalToConstant: Self.buttonWidth).isActive = true
        cells.append(plus)
        for start in stride(from: 0, to: cells.count, by: 3) {
            var row = Array(cells[start..<min(cells.count, start + 3)])
            while row.count < 3 { row.append(NSGridCell.emptyContentView) }
            grid.addRow(with: row)
        }
    }

    /// The button, and for the user's presets the × on its corner, outside the title.
    private func cell(_ item: Item) -> NSView {
        let b = button(item)
        guard item.user else { return b }
        let holder = NSView()
        holder.translatesAutoresizingMaskIntoConstraints = false
        b.removeFromSuperview()
        holder.addSubview(b)
        let x = NSButton(image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Delete \(item.title)")!
            .withSymbolConfiguration(.init(pointSize: 9, weight: .regular))!, target: self, action: #selector(delete(_:)))
        x.isBordered = false
        x.contentTintColor = NSColor(white: 1, alpha: 0.4)
        x.identifier = b.identifier
        x.toolTip = "Delete \(item.title)"
        x.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(x)
        NSLayoutConstraint.activate([
            b.leadingAnchor.constraint(equalTo: holder.leadingAnchor), b.trailingAnchor.constraint(equalTo: holder.trailingAnchor),
            b.topAnchor.constraint(equalTo: holder.topAnchor), b.bottomAnchor.constraint(equalTo: holder.bottomAnchor),
            x.centerXAnchor.constraint(equalTo: holder.trailingAnchor, constant: -2),
            x.centerYAnchor.constraint(equalTo: holder.topAnchor, constant: 2),
            x.widthAnchor.constraint(equalToConstant: 12), x.heightAnchor.constraint(equalToConstant: 12),
        ])
        return holder
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
        guard item.user else { return b }
        b.toolTip = "Your preset: the × on its corner deletes it, a right click replaces it with the look on screen"
        let menu = NSMenu()
        let replace = menu.addItem(withTitle: "Replace with the Look on Screen", action: #selector(replace(_:)), keyEquivalent: "")
        replace.target = self
        replace.representedObject = item.id
        let delete = menu.addItem(withTitle: "Delete “\(item.title)”", action: #selector(deleteItem(_:)), keyEquivalent: "")
        delete.target = self
        delete.representedObject = item.id
        b.menu = menu
        return b
    }

    @objc private func pick(_ sender: NSButton) { sender.identifier.map { onPick($0.rawValue) } }
    @objc private func delete(_ sender: NSButton) { sender.identifier.map { onDelete($0.rawValue) } }
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
