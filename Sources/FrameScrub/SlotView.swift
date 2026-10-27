import AppKit
import HomeChrome
import FrameScrubCore
import QuartzCore

/// One slot at the window's edge (left, right or bottom): a thin header (the view's name with its menu, pin/float,
/// backdrop, hide), the backdrop and the view itself — the playlist or a plugin page — below it. An empty slot shows a
/// "+" in its middle. The slot's own layer is all that moves when it shows or hides; the video under it is untouched.
/// Its frame is set by `SlotsController`. An overlay slot looks and moves as a compact browser sidebar does: a card a
/// little off the edges with a soft shadow, sliding in on a light spring.
@MainActor final class SlotView: NSView {
    static let headerHeight: CGFloat = 30
    /// Overlay slots keep this far from the video's edges.
    static let overlayInset: CGFloat = 8
    private static let overlayCornerRadius: CGFloat = 10
    /// The grab zone of the inner edge, half of it outside an overlay card.
    private static let gripWidth: CGFloat = 8
    /// Graphite: a pinned slot, and the dark backdrop.
    private static let darkColor = NSColor(srgbRed: 20 / 255, green: 20 / 255, blue: 22 / 255, alpha: 1)

    let edge: SlotEdge
    /// The playlist view or a plugin page; fills the slot below the header.
    var content: NSView? {
        didSet {
            guard content !== oldValue else { return }
            if oldValue?.superview === contentHost { oldValue?.removeFromSuperview() }
            if let content { host(content) }
            updateEmptyState()
            applyTextShadow(mode == .overlay && backdrop == .clear)
        }
    }
    var title = "" { didSet { titleButton.title = title + " ▾" } }
    /// Shown in the middle of a slot without a view (a plugin that is not in the config any more).
    var note: String? { didSet { updateEmptyState() } }
    var mode = SlotMode.overlay { didSet { applyLook() } }
    /// Applies in overlay; a pinned slot is always dark.
    var backdrop = SlotBackdrop.glass { didSet { applyLook() } }

    /// The size the drag of the inner edge asks for (not clamped), and the drag's end.
    var onResize: ((CGFloat) -> Void)?
    var onResizeEnd: (() -> Void)?
    /// ▾ next to the name: replace / move / auto-hide / clear.
    var onHeaderMenu: ((NSView) -> Void)?
    var onTogglePin: (() -> Void)?
    var onCycleBackdrop: (() -> Void)?
    var onClose: (() -> Void)?
    /// The "+" of an empty slot.
    var onPlus: ((NSView) -> Void)?

    /// Shown, or on its way in; false once a hide has begun.
    private(set) var isShown = false
    /// The inner edge is being dragged.
    var isResizing: Bool { grip.isDragging }

    private let panel = NSView()
    /// Glass: the video blurred and darkened behind the slot, so any text on it reads on any picture.
    private let blur = NSVisualEffectView()
    /// A dark veil over the blur (glass) or straight over the video (clear).
    private let veil = NSView()
    private let header = NSView()
    private let titleButton = NSButton(title: "", target: nil, action: nil)
    private let pinButton = SlotView.symbolButton("pin", "Pin / Float")
    private let backdropButton = SlotView.symbolButton("circle.lefthalf.filled", "Next Backdrop")
    private let closeButton = SlotView.symbolButton("xmark", "Hide")
    private let contentHost = NSView()
    private let plusButton = NSButton(frame: .zero)
    private let noteLabel = NSTextField(wrappingLabelWithString: "")
    /// A hairline on the inner side of a pinned slot.
    private let separator = NSView()
    private let grip: SlotGripView
    private var panelInsets: [NSLayoutConstraint] = []
    private var gripPlace: [NSLayoutConstraint] = []

    init(edge: SlotEdge) {
        self.edge = edge
        grip = SlotGripView(edge: edge)
        super.init(frame: .zero)
        wantsLayer = true
        appearance = NSAppearance(named: .darkAqua)
        isHidden = true
        for view in [panel, separator, grip] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        panel.wantsLayer = true
        panel.layer?.masksToBounds = true
        panel.layer?.cornerCurve = .continuous
        for view in [blur, veil, header, contentHost, plusButton, noteLabel] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            panel.addSubview(view)
        }
        blur.material = .hudWindow
        blur.blendingMode = .withinWindow
        blur.state = .active
        veil.wantsLayer = true
        header.wantsLayer = true
        contentHost.wantsLayer = true
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOffset = CGSize(width: 0, height: -3)
        layer?.shadowRadius = 4
        buildHeader()
        // A symbol in a round plate: a "+" typed as a title sits off-centre in a circular bezel.
        plusButton.isBordered = false
        plusButton.image = Lucide.icon("plus", pointSize: 20, weight: .light, description: "Choose what this slot shows")
        plusButton.imagePosition = .imageOnly
        plusButton.imageScaling = .scaleNone
        plusButton.contentTintColor = .labelColor
        plusButton.wantsLayer = true
        plusButton.layer?.cornerRadius = Self.plusSize / 2
        plusButton.layer?.backgroundColor = NSColor(white: 1, alpha: 0.12).cgColor
        plusButton.target = self
        plusButton.action = #selector(plusPressed)
        plusButton.toolTip = "Choose what this slot shows"
        noteLabel.alignment = .center
        noteLabel.textColor = .secondaryLabelColor
        noteLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        separator.wantsLayer = true
        separator.layer?.backgroundColor = NSColor(white: 1, alpha: 0.12).cgColor
        let pad: CGFloat = 16
        for backdrop in [blur, veil] {
            NSLayoutConstraint.activate([
                backdrop.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
                backdrop.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
                backdrop.topAnchor.constraint(equalTo: panel.topAnchor),
                backdrop.bottomAnchor.constraint(equalTo: panel.bottomAnchor),
            ])
        }
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            header.topAnchor.constraint(equalTo: panel.topAnchor),
            header.heightAnchor.constraint(equalToConstant: Self.headerHeight),
            contentHost.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            contentHost.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            contentHost.topAnchor.constraint(equalTo: header.bottomAnchor),
            contentHost.bottomAnchor.constraint(equalTo: panel.bottomAnchor),
            plusButton.widthAnchor.constraint(equalToConstant: Self.plusSize),
            plusButton.heightAnchor.constraint(equalToConstant: Self.plusSize),
            plusButton.centerXAnchor.constraint(equalTo: contentHost.centerXAnchor),
            plusButton.centerYAnchor.constraint(equalTo: contentHost.centerYAnchor),
            noteLabel.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: pad),
            noteLabel.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -pad),
            noteLabel.bottomAnchor.constraint(equalTo: plusButton.topAnchor, constant: -12),
        ])
        switch edge {
        case .left:
            NSLayoutConstraint.activate([
                separator.trailingAnchor.constraint(equalTo: trailingAnchor), separator.widthAnchor.constraint(equalToConstant: 1),
                separator.topAnchor.constraint(equalTo: topAnchor), separator.bottomAnchor.constraint(equalTo: bottomAnchor),
                grip.widthAnchor.constraint(equalToConstant: Self.gripWidth),
                grip.topAnchor.constraint(equalTo: panel.topAnchor), grip.bottomAnchor.constraint(equalTo: panel.bottomAnchor),
            ])
        case .right:
            NSLayoutConstraint.activate([
                separator.leadingAnchor.constraint(equalTo: leadingAnchor), separator.widthAnchor.constraint(equalToConstant: 1),
                separator.topAnchor.constraint(equalTo: topAnchor), separator.bottomAnchor.constraint(equalTo: bottomAnchor),
                grip.widthAnchor.constraint(equalToConstant: Self.gripWidth),
                grip.topAnchor.constraint(equalTo: panel.topAnchor), grip.bottomAnchor.constraint(equalTo: panel.bottomAnchor),
            ])
        case .bottom:
            NSLayoutConstraint.activate([
                separator.topAnchor.constraint(equalTo: topAnchor), separator.heightAnchor.constraint(equalToConstant: 1),
                separator.leadingAnchor.constraint(equalTo: leadingAnchor), separator.trailingAnchor.constraint(equalTo: trailingAnchor),
                grip.heightAnchor.constraint(equalToConstant: Self.gripWidth),
                grip.leadingAnchor.constraint(equalTo: panel.leadingAnchor), grip.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            ])
        }
        grip.onDrag = { [weak self] in self?.onResize?($0) }
        grip.onEnd = { [weak self] in self?.onResizeEnd?() }
        grip.currentSize = { [weak self] in
            guard let self else { return 0 }
            return edge == .bottom ? frame.height : frame.width
        }
        applyLook()
        updateEmptyState()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private static let plusSize: CGFloat = 44

    private static func symbolButton(_ symbol: String, _ tip: String) -> NSButton {
        let button = NSButton(image: Lucide.icon(symbol, pointSize: 13, description: tip) ?? NSImage(),
                              target: nil, action: nil)
        button.isBordered = false
        button.toolTip = tip
        button.contentTintColor = .secondaryLabelColor
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 22).isActive = true
        return button
    }

    private func buildHeader() {
        titleButton.isBordered = false
        titleButton.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        titleButton.contentTintColor = .labelColor
        titleButton.target = self
        titleButton.action = #selector(titlePressed)
        titleButton.lineBreakMode = .byTruncatingTail
        titleButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        pinButton.target = self
        pinButton.action = #selector(pinPressed)
        backdropButton.target = self
        backdropButton.action = #selector(backdropPressed)
        closeButton.target = self
        closeButton.action = #selector(closePressed)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let stack = NSStackView(views: [titleButton, spacer, pinButton, backdropButton, closeButton])
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            stack.topAnchor.constraint(equalTo: header.topAnchor),
            stack.bottomAnchor.constraint(equalTo: header.bottomAnchor),
        ])
    }

    private func host(_ view: NSView) {
        view.removeFromSuperview()
        view.translatesAutoresizingMaskIntoConstraints = false
        contentHost.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: contentHost.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: contentHost.trailingAnchor),
            view.topAnchor.constraint(equalTo: contentHost.topAnchor),
            view.bottomAnchor.constraint(equalTo: contentHost.bottomAnchor),
        ])
        view.isHidden = false
    }

    private func updateEmptyState() {
        plusButton.isHidden = content != nil
        noteLabel.stringValue = note ?? ""
        noteLabel.isHidden = content != nil || note == nil
    }

    /// Overlay: a card a little off the video's edges, rounded, shadowed, with the chosen backdrop. Pinned: flush,
    /// graphite, a hairline on the inner side.
    private func applyLook() {
        let overlay = mode == .overlay
        NSLayoutConstraint.deactivate(panelInsets + gripPlace)
        let inset = overlay ? Self.overlayInset : 0
        panelInsets = [
            panel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            panel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            panel.topAnchor.constraint(equalTo: topAnchor, constant: inset),
            panel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -inset),
        ]
        // The grip straddles the card's inner edge (inside the slot's frame, so it takes the clicks).
        let half = overlay ? Self.gripWidth / 2 : 0
        gripPlace = switch edge {
        case .left: [grip.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: half)]
        case .right: [grip.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: -half)]
        case .bottom: [grip.topAnchor.constraint(equalTo: panel.topAnchor, constant: -half)]
        }
        NSLayoutConstraint.activate(panelInsets + gripPlace)
        let look = overlay ? backdrop : .dark
        panel.layer?.cornerRadius = overlay ? Self.overlayCornerRadius : 0
        panel.layer?.backgroundColor = look == .dark ? Self.darkColor.cgColor : NSColor.clear.cgColor
        panel.layer?.borderWidth = overlay ? 1 : 0
        panel.layer?.borderColor = NSColor(white: 1, alpha: 0.1).cgColor
        blur.isHidden = look != .glass
        veil.isHidden = look == .dark
        veil.layer?.backgroundColor = NSColor(white: 0, alpha: look == .glass ? 0.3 : 0.35).cgColor
        layer?.shadowOpacity = overlay ? 0.24 : 0
        applyTextShadow(look == .clear)
        separator.isHidden = overlay
        backdropButton.isHidden = !overlay
        pinButton.image = Lucide.icon(overlay ? "pin" : "pin.fill", pointSize: 13, description: "Pin / Float")
        needsLayout = true
    }

    /// On the clear backdrop the header, and the playlist, get a shadow under their text; a page draws its own.
    private func applyTextShadow(_ on: Bool) {
        let views: [NSView] = content is PluginPanel ? [header] : [header, contentHost]
        for view in [header, contentHost] {
            let shadowed = on && views.contains(view)
            view.layer?.shadowColor = NSColor.black.cgColor
            view.layer?.shadowOpacity = shadowed ? 0.9 : 0
            view.layer?.shadowRadius = 1.5
            view.layer?.shadowOffset = CGSize(width: 0, height: -1)
        }
    }

    override func layout() {
        super.layout()
        // The card's shadow follows its rounded shape (a path: no offscreen pass while it moves).
        layer?.shadowPath = mode == .overlay
            ? CGPath(roundedRect: panel.frame, cornerWidth: Self.overlayCornerRadius,
                     cornerHeight: Self.overlayCornerRadius, transform: nil)
            : nil
    }

    // MARK: Showing and hiding

    /// Slides in from the slot's edge on a light spring (about 0.3 s, overshooting by about 1%), and out in 0.15 s;
    /// with Reduce Motion a short fade instead. Only this view's layer animates.
    func setShown(_ shown: Bool, animated: Bool, completion: (() -> Void)? = nil) {
        isShown = shown
        guard let layer else { isHidden = !shown; completion?(); return }
        layer.removeAnimation(forKey: "slot")
        if shown { isHidden = false }
        guard animated, window != nil else {
            isHidden = !shown
            completion?()
            return
        }
        let animation: CAAnimation
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = shown ? 0 : 1
            fade.toValue = shown ? 1 : 0
            fade.duration = 0.15
            animation = fade
        } else {
            let keyPath = edge == .bottom ? "transform.translation.y" : "transform.translation.x"
            let away: CGFloat = switch edge {
            case .left: -bounds.width
            case .right: bounds.width
            case .bottom: -bounds.height
            }
            if shown {
                let spring = CASpringAnimation(keyPath: keyPath)
                spring.mass = 1
                spring.stiffness = 300
                spring.damping = 28.4   // damping ratio 0.82: about 1% past the mark, then back
                spring.fromValue = away
                spring.toValue = 0
                spring.duration = spring.settlingDuration
                animation = spring
            } else {
                let slide = CABasicAnimation(keyPath: keyPath)
                slide.fromValue = 0
                slide.toValue = away
                slide.duration = 0.15
                slide.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                animation = slide
            }
        }
        animation.fillMode = .forwards
        animation.isRemovedOnCompletion = false
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isShown == shown else { return }   // a newer show or hide took over
                if !shown { self.isHidden = true }
                self.layer?.removeAnimation(forKey: "slot")
                completion?()
            }
        }
        layer.add(animation, forKey: "slot")
        CATransaction.commit()
    }

    /// Clicks pass through a slot that is hidden or on its way out.
    override func hitTest(_ point: NSPoint) -> NSView? {
        isShown ? super.hitTest(point) : nil
    }

    /// Whether `view` (the window's first responder, usually) is inside this slot.
    func holds(_ view: NSView?) -> Bool {
        var view = view
        while let current = view {
            if current === self { return true }
            view = current.superview
        }
        return false
    }

    @objc private func titlePressed() { onHeaderMenu?(titleButton) }
    @objc private func pinPressed() { onTogglePin?() }
    @objc private func backdropPressed() { onCycleBackdrop?() }
    @objc private func closePressed() { onClose?() }
    @objc private func plusPressed() { onPlus?(plusButton) }

    /// Opens the "+" menu, as a click on it would.
    func pressPlus() { onPlus?(plusButton) }
}

/// The inner edge of a slot: a resize cursor and a light line while the pointer is on it; a drag reports the size it
/// asks for.
@MainActor private final class SlotGripView: NSView {
    let edge: SlotEdge
    var onDrag: ((CGFloat) -> Void)?
    var onEnd: (() -> Void)?
    var currentSize: (() -> CGFloat)?
    var isDragging: Bool { start != nil }
    private var start: (point: NSPoint, size: CGFloat)?
    private var hovered = false { didSet { line.isHidden = !(hovered || isDragging) } }
    private let line = NSView()

    init(edge: SlotEdge) {
        self.edge = edge
        super.init(frame: .zero)
        line.wantsLayer = true
        line.layer?.backgroundColor = NSColor(white: 1, alpha: 0.45).cgColor
        line.layer?.cornerRadius = 1
        line.isHidden = true
        addSubview(line)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                       owner: self))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        line.frame = edge == .bottom
            ? CGRect(x: 0, y: bounds.midY - 1, width: bounds.width, height: 2)
            : CGRect(x: bounds.midX - 1, y: 0, width: 2, height: bounds.height)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: edge == .bottom ? .resizeUpDown : .resizeLeftRight)
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        start = (event.locationInWindow, currentSize?() ?? 0)
        line.isHidden = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start else { return }
        let p = event.locationInWindow
        let size = switch edge {
        case .left: start.size + (p.x - start.point.x)
        case .right: start.size + (start.point.x - p.x)
        case .bottom: start.size + (p.y - start.point.y)
        }
        onDrag?(size)
    }

    override func mouseUp(with event: NSEvent) {
        start = nil
        line.isHidden = !hovered
        onEnd?()
    }
}

/// The tongue at a window edge (spec §3.7), for a slot revealed with a click: a short pill that fades in as the pointer
/// nears the edge and follows it along. Its frame is wider than the pill, so it is easy to hit.
@MainActor final class SlotTongueView: NSView {
    /// The pill's thickness, and the frame's (the grab zone).
    static let thickness: CGFloat = 6
    static let hitThickness: CGFloat = 16
    let edge: SlotEdge
    var onClick: (() -> Void)?
    private let pill = NSView()

    init(edge: SlotEdge) {
        self.edge = edge
        super.init(frame: .zero)
        pill.wantsLayer = true
        pill.layer?.backgroundColor = NSColor(white: 1, alpha: 0.75).cgColor
        pill.layer?.cornerRadius = Self.thickness / 2
        pill.layer?.borderColor = NSColor(white: 0, alpha: 0.4).cgColor
        pill.layer?.borderWidth = 0.5
        pill.layer?.shadowColor = NSColor.black.cgColor
        pill.layer?.shadowOpacity = 0.4
        pill.layer?.shadowRadius = 2
        pill.layer?.shadowOffset = .zero
        addSubview(pill)
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let t = Self.thickness, gap: CGFloat = 3
        pill.frame = switch edge {
        case .left: CGRect(x: gap, y: 0, width: t, height: bounds.height)
        case .right: CGRect(x: bounds.width - t - gap, y: 0, width: t, height: bounds.height)
        case .bottom: CGRect(x: 0, y: gap, width: bounds.width, height: t)
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick?() }
}
