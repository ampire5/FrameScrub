import AppKit
import FrameScrubCore
import HomeChrome
import QuartzCore

/// One tab of a slot: the playlist or a plugin page.
public struct SlotTab: Equatable {
    public let id: String
    /// An icon name (`Icons.symbol`); without one, `letter` in a rounded square.
    public let symbol: String?
    public let letter: String?
    public let name: String
    public var selected: Bool

    public init(id: String, symbol: String?, letter: String?, name: String, selected: Bool) {
        self.id = id
        self.symbol = symbol
        self.letter = letter
        self.name = name
        self.selected = selected
    }
}

/// A tool the shown view puts in the capsule (the playlist's filter and order). A tool with a menu opens it on a
/// click; otherwise the click runs `action`.
public struct SlotTool {
    public let id: String
    public let symbol: String
    /// Drawn in the accent colour (the filter while it holds text).
    public var accent: Bool
    public let tip: String
    public let menu: (() -> NSMenu)?
    public let action: (() -> Void)?

    public init(id: String, symbol: String, accent: Bool = false, tip: String, menu: (() -> NSMenu)? = nil,
                action: (() -> Void)? = nil) {
        self.id = id
        self.symbol = symbol
        self.accent = accent
        self.tip = tip
        self.menu = menu
        self.action = action
    }
}

/// The slot's capsule (spec 2026-10-28-slot-capsule): a glass bar at the top of the slot's card, over its view. Left the
/// tabs and **+**, then the shown view's tools, right the slot's pin, backdrop and hide. 🔍 or ⌘F opens a filter field in
/// place of the tabs and tools. Laid out by frames; buttons are kept and reused, so a tab switch builds nothing.
@MainActor public final class SlotCapsuleView: NSView, NSSearchFieldDelegate {
    public static let height: CGFloat = 28
    /// From the card's edges.
    public static let margin: CGFloat = 6
    private static let buttonSize = CGSize(width: 28, height: 24)
    private static let pad: CGFloat = 2
    private static let primary = NSColor(srgbRed: 0xf2 / 255, green: 0xf2 / 255, blue: 0xf7 / 255, alpha: 1)
    private static let secondary = NSColor(srgbRed: 0x9a / 255, green: 0x9a / 255, blue: 0xa2 / 255, alpha: 1)

    /// Which way the hide chevron points.
    public var edge: SlotEdge { didSet { if edge != oldValue { updateSlotButtons() } } }
    public var tabs: [SlotTab] = [] { didSet { if tabs != oldValue { updateTabs() } } }
    public var tools: [SlotTool] = [] { didSet { updateTools() } }
    public var pinned = false { didSet { if pinned != oldValue { updateSlotButtons() } } }
    public var showsBackdropButton = true {
        didSet { backdropButton.isHidden = !showsBackdropButton; needsLayout = true }
    }

    public var onSelectTab: ((String) -> Void)?
    /// A right click on a tab: its menu, shown under it.
    public var onTabMenu: ((String) -> NSMenu?)?
    public var onPlus: ((NSView) -> Void)?
    public var onPin: (() -> Void)?
    public var onBackdrop: (() -> Void)?
    public var onHide: (() -> Void)?
    /// A right click on the capsule's empty part.
    public var onCapsuleMenu: (() -> NSMenu?)?
    public var onFilterText: ((String) -> Void)?
    public var onFilterSubmit: (() -> Void)?
    /// The field closed (Esc on an empty field, or `endFilter`): the keys go back to the player.
    public var onFilterEnd: (() -> Void)?
    /// A menu of the capsule opened or closed.
    public var onMenuTracking: ((Bool) -> Void)?

    /// The pointer is over the capsule: it holds the capsule (and its slot) up.
    public private(set) var isPointerInside = false
    public var isEditingFilter: Bool { field.map { !$0.isHidden } ?? false }
    public private(set) var isVisible = false

    private let blur = NSVisualEffectView()
    private let veil = NSView()
    private var tabButtons: [CapsuleButton] = []
    private let plusButton = CapsuleButton()
    private var toolButtons: [CapsuleButton] = []
    private let pinButton = CapsuleButton()
    private let backdropButton = CapsuleButton()
    private let hideButton = CapsuleButton()
    private let dividers = [NSView(), NSView()]
    private var field: NSSearchField?
    private var tracking: NSTrackingArea?

    public init(edge: SlotEdge) {
        self.edge = edge
        super.init(frame: NSRect(x: 0, y: 0, width: 200, height: Self.height))
        wantsLayer = true
        appearance = NSAppearance(named: .darkAqua)
        layer?.cornerRadius = Self.height / 2
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor(white: 1, alpha: 0.14).cgColor
        blur.material = .hudWindow
        blur.blendingMode = .withinWindow
        blur.state = .active
        veil.wantsLayer = true
        veil.layer?.backgroundColor = NSColor(white: 0, alpha: 0.35).cgColor
        addSubview(blur)
        addSubview(veil)
        for divider in dividers {
            divider.wantsLayer = true
            divider.layer?.backgroundColor = NSColor(white: 1, alpha: 0.18).cgColor
            addSubview(divider)
        }
        configure(plusButton, symbol: "plus", tip: "Add a View")
        plusButton.onClick = { [weak self] in
            guard let self else { return }
            onPlus?(plusButton)
        }
        configure(pinButton, symbol: "pin", tip: "Pin / Float")
        pinButton.onClick = { [weak self] in self?.onPin?() }
        configure(backdropButton, symbol: "circle.lefthalf.filled", tip: "Next Backdrop")
        backdropButton.onClick = { [weak self] in self?.onBackdrop?() }
        configure(hideButton, symbol: "chevron.right", tip: "Hide")
        hideButton.onClick = { [weak self] in self?.onHide?() }
        for button in [plusButton, pinButton, backdropButton, hideButton] { addSubview(button) }
        updateSlotButtons()
        setAccessibilityElement(true)
        setAccessibilityRole(.toolbar)
        setAccessibilityLabel("Slot")
        alphaValue = 0
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Buttons

    private func configure(_ button: CapsuleButton, symbol: String?, letter: String? = nil, tip: String) {
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleNone
        button.toolTip = tip
        button.setAccessibilityLabel(tip)
        button.wantsLayer = true
        button.layer?.cornerRadius = Self.buttonSize.height / 2
        button.layer?.cornerCurve = .continuous
        if let symbol {
            button.image = Icons.symbol(symbol, pointSize: 13, description: tip)
            button.title = ""
            button.letterBox = false
        } else {
            button.image = nil
            button.imagePosition = .noImage
            button.attributedTitle = NSAttributedString(string: letter ?? "?", attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: Self.primary])
            button.letterBox = true
        }
        button.contentTintColor = Self.primary
    }

    private func updateTabs() {
        while tabButtons.count < tabs.count {
            let button = CapsuleButton()
            addSubview(button)
            tabButtons.append(button)
        }
        for (i, button) in tabButtons.enumerated() {
            guard i < tabs.count else { button.isHidden = true; continue }
            let tab = tabs[i]
            if button.tabID != tab.id {
                configure(button, symbol: tab.symbol, letter: tab.letter, tip: tab.name)
                button.tabID = tab.id
                button.isTab = true
                button.onClick = { [weak self] in self?.onSelectTab?(tab.id) }
                button.onRightClick = { [weak self, weak button] in
                    guard let self, let button, let menu = onTabMenu?(tab.id) else { return }
                    popUp(menu, under: button)
                }
            }
            button.isHidden = isEditingFilter
            button.selectedLook = tab.selected
            button.setAccessibilityValue(tab.selected ? "selected" : nil)
        }
        needsLayout = true
    }

    private func updateTools() {
        while toolButtons.count < tools.count {
            let button = CapsuleButton()
            addSubview(button)
            toolButtons.append(button)
        }
        for (i, button) in toolButtons.enumerated() {
            guard i < tools.count else { button.isHidden = true; continue }
            let tool = tools[i]
            if button.tabID != tool.id {
                configure(button, symbol: tool.symbol, tip: tool.tip)
                button.tabID = tool.id
            }
            button.toolTip = tool.tip
            button.contentTintColor = tool.accent ? .controlAccentColor : Self.primary
            button.onClick = { [weak self, weak button] in
                guard let self, let button else { return }
                if let menu = tool.menu?() { popUp(menu, under: button) } else { tool.action?() }
            }
            button.isHidden = isEditingFilter
        }
        needsLayout = true
    }

    private func updateSlotButtons() {
        pinButton.image = Icons.symbol(pinned ? "pin.fill" : "pin", pointSize: 13, description: "Pin / Float")
        let chevron = switch edge {
        case .left: "chevron.left"
        case .right: "chevron.right"
        case .bottom: "chevron.down"
        }
        hideButton.image = Icons.symbol(chevron, pointSize: 13, description: "Hide")
    }

    private func popUp(_ menu: NSMenu, under view: NSView) {
        onMenuTracking?(true)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.minY - 4), in: view)
        onMenuTracking?(false)
    }

    // MARK: Layout

    override public var isFlipped: Bool { true }

    override public func layout() {
        super.layout()
        blur.frame = bounds
        veil.frame = bounds
        let size = Self.buttonSize
        let y = ((bounds.height - size.height) / 2).rounded()
        var x = Self.pad
        func place(_ view: NSView) {
            guard !view.isHidden else { return }
            view.frame = CGRect(x: x, y: y, width: size.width, height: size.height)
            x += size.width
        }
        // Right: the slot's buttons, from the end.
        var right = bounds.width - Self.pad
        for button in [hideButton, backdropButton, pinButton] where !button.isHidden {
            right -= size.width
            button.frame = CGRect(x: right, y: y, width: size.width, height: size.height)
        }
        dividers[1].frame = CGRect(x: right - 4, y: (bounds.height - 14) / 2, width: 1, height: 14)
        if let field, !field.isHidden {
            field.frame = CGRect(x: Self.pad + 6, y: (bounds.height - 22) / 2, width: max(40, right - 10 - Self.pad - 6),
                                 height: 22)
            dividers[0].isHidden = true
            return
        }
        for button in tabButtons.prefix(tabs.count) { place(button) }
        place(plusButton)
        let hasTools = !tools.isEmpty
        dividers[0].isHidden = !hasTools
        if hasTools {
            dividers[0].frame = CGRect(x: x + 3, y: (bounds.height - 14) / 2, width: 1, height: 14)
            x += 7
            for button in toolButtons.prefix(tools.count) { place(button) }
        }
    }

    // MARK: Showing

    /// Fades in or out (`CapsuleClock.fadeIn` / `SlotMotion.fade`); hidden when out, so clicks reach the view under it.
    public func setVisible(_ visible: Bool, animated: Bool) {
        guard visible != isVisible else { return }
        isVisible = visible
        if visible { isHidden = false }
        guard animated else {
            alphaValue = visible ? 1 : 0
            isHidden = !visible
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = visible ? CapsuleClock.fadeIn : SlotMotion.fade
            context.timingFunction = CAMediaTimingFunction(name: visible ? .easeOut : .easeIn)
            animator().alphaValue = visible ? 1 : 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.isVisible else { return }
                self.isHidden = true
            }
        }
    }

    // MARK: Filter

    /// Opens the filter field in place of the tabs and tools, with `text`, and gives it the keyboard.
    public func beginFilter(text: String) {
        let field = field ?? makeField()
        field.stringValue = text
        field.isHidden = false
        setRowHidden(true)
        needsLayout = true
        layoutSubtreeIfNeeded()
        window?.makeFirstResponder(field)
    }

    /// Closes the field (the text stays with the playlist).
    public func endFilter() {
        guard let field, !field.isHidden else { return }
        let hadKeys = field.currentEditor() != nil
        field.isHidden = true
        setRowHidden(false)
        needsLayout = true
        if hadKeys { onFilterEnd?() }
    }

    private func setRowHidden(_ hidden: Bool) {
        for button in tabButtons.prefix(tabs.count) + toolButtons.prefix(tools.count) { button.isHidden = hidden }
        plusButton.isHidden = hidden
    }

    private func makeField() -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = "Filter"
        field.controlSize = .small
        field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        field.sendsSearchStringImmediately = true
        field.delegate = self
        field.isHidden = true
        addSubview(field)
        self.field = field
        return field
    }

    public func controlTextDidChange(_ obj: Notification) {
        guard let field else { return }
        onFilterText?(field.stringValue)
    }

    public func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard let field else { return false }
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            onFilterSubmit?()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            if field.stringValue.isEmpty {
                endFilter()
            } else {
                field.stringValue = ""
                onFilterText?("")
            }
            return true
        default:
            return false
        }
    }

    // MARK: Pointer

    override public func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override public func mouseEntered(with event: NSEvent) { isPointerInside = true }
    override public func mouseExited(with event: NSEvent) { isPointerInside = false }

    override public func rightMouseDown(with event: NSEvent) {
        guard let menu = onCapsuleMenu?() else { return }
        onMenuTracking?(true)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
        onMenuTracking?(false)
    }

    /// The capsule takes the clicks inside it (not the view under it), but none while hidden.
    override public func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, isVisible else { return nil }
        return super.hitTest(point) ?? (frame.contains(point) ? self : nil)
    }
}

/// A round button of the capsule: hover and selected chips, a right click of its own.
@MainActor final class CapsuleButton: NSButton {
    var onClick: (() -> Void)?
    var onRightClick: (() -> Void)?
    /// The tab or tool it shows, so a rebuild of the list reconfigures only what changed.
    var tabID: String?
    /// A letter in a rounded square (a page without an icon).
    var letterBox = false { didSet { updateLook() } }
    var selectedLook = false { didSet { if selectedLook != oldValue { updateLook() } } }
    private var hovered = false { didSet { if hovered != oldValue { updateLook() } } }
    private var tracking: NSTrackingArea?

    init() {
        super.init(frame: .zero)
        target = self
        action = #selector(fire)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func fire() { onClick?() }

    override func rightMouseDown(with event: NSEvent) {
        if let onRightClick { onRightClick() } else { super.rightMouseDown(with: event) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }

    private func updateLook() {
        let fill: CGFloat = selectedLook ? 0.2 : hovered ? 0.1 : 0
        layer?.backgroundColor = NSColor(white: 1, alpha: fill).cgColor
        alphaValue = selectedLook || hovered || tabID == nil || !isTab ? 1 : 0.7
        layer?.borderWidth = letterBox ? 1 : 0
        layer?.borderColor = NSColor(white: 1, alpha: 0.4).cgColor
    }

    /// Tabs are drawn at 70 % until selected; tools and the slot's buttons are not tabs.
    var isTab = false { didSet { updateLook() } }
}
