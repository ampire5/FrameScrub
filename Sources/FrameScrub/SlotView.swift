import AppKit
import HomeChrome
import FrameScrubCore
import QuartzCore
import SlotChrome

/// One slot at the window's edge (left, right or bottom): the backdrop, its views (the playlist, plugin pages: one per
/// tab, the shown one visible, the others kept hidden) at the card's full height, and the capsule over their top (tabs,
/// the view's tools, pin / backdrop / hide; `SlotCapsuleView`). An empty slot shows a "+" in its middle. The slot's own layer is all that moves when it shows or hides; the video under it is untouched.
/// Its frame is set by `SlotsController`. An overlay slot looks and moves as a compact browser sidebar does: a card a
/// little off the edges with a soft shadow, sliding in and out on the same light spring (Zen's compact sidebar).
@MainActor final class SlotView: NSView {
    /// Overlay slots keep this far from the video's edges (Zen: half its 8 px separation).
    static let overlayInset: CGFloat = 4
    private static let overlayCornerRadius: CGFloat = 10
    /// The grab zone of the inner edge, half of it outside an overlay card.
    private static let gripWidth: CGFloat = 8
    /// Graphite: a pinned slot, and the dark backdrop.
    private static let darkColor = NSColor(srgbRed: 20 / 255, green: 20 / 255, blue: 22 / 255, alpha: 1)

    let edge: SlotEdge
    let capsule: SlotCapsuleView
    /// The tabs' views by id; each fills the card. Only `shownView` is visible.
    private(set) var views: [String: NSView] = [:]
    private(set) var shownView: NSView?
    /// Shown in the middle of a slot without a view (a plugin that is not in the config any more).
    var note: String? { didSet { updateEmptyState() } }
    var mode = SlotMode.overlay { didSet { applyLook() } }
    /// Applies in overlay; a pinned slot is always dark.
    var backdrop = SlotBackdrop.glass { didSet { applyLook() } }

    /// The size the drag of the inner edge asks for (not clamped), and the drag's end.
    var onResize: ((CGFloat) -> Void)?
    var onResizeEnd: (() -> Void)?
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
        capsule = SlotCapsuleView(edge: edge)
        super.init(frame: .zero)
        wantsLayer = true
        appearance = NSAppearance(named: .darkAqua)
        isHidden = true
        for view in [panel, separator, grip] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        panel.wantsLayer = true
        panel.layer?.masksToBounds = true
        panel.layer?.cornerCurve = .continuous
        for view in [blur, veil, contentHost, plusButton, noteLabel] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            panel.addSubview(view)
        }
        panel.addSubview(capsule)   // over the views; placed by frame in layout()
        blur.material = .hudWindow
        blur.blendingMode = .withinWindow
        blur.state = .active
        veil.wantsLayer = true
        contentHost.wantsLayer = true
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOffset = CGSize(width: 0, height: -3)
        layer?.shadowRadius = 4
        // A symbol in a round plate: a "+" typed as a title sits off-centre in a circular bezel.
        plusButton.isBordered = false
        plusButton.image = Icons.symbol("plus", pointSize: 20, weight: .light, description: "Choose what this slot shows")
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
            contentHost.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            contentHost.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            contentHost.topAnchor.constraint(equalTo: panel.topAnchor),
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

    /// The slot's tabs' views by id, and the one shown. Views already here stay (nothing is rebuilt); views no longer
    /// listed leave; the others are hidden, out of hit testing and VoiceOver.
    func setViews(_ views: [String: NSView], shown id: String?) {
        for (key, old) in self.views where views[key] !== old && old.superview === contentHost { old.removeFromSuperview() }
        for (_, view) in views where view.superview !== contentHost { host(view) }
        self.views = views
        let shown = id.flatMap { views[$0] }
        for (_, view) in views {
            let visible = view === shown
            if view.isHidden == visible { view.isHidden = !visible }
            view.setAccessibilityElement(visible)
        }
        shownView = shown
        updateEmptyState()
        applyTextShadow(mode == .overlay && backdrop == .clear)
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
    }

    private func updateEmptyState() {
        plusButton.isHidden = shownView != nil
        noteLabel.stringValue = note ?? ""
        noteLabel.isHidden = shownView != nil || note == nil
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
        panel.layer?.borderColor = NSColor(white: 1, alpha: 0.15).cgColor
        blur.isHidden = look != .glass
        veil.isHidden = look == .dark
        veil.layer?.backgroundColor = NSColor(white: 0, alpha: look == .glass ? 0.3 : 0.35).cgColor
        layer?.shadowOpacity = overlay ? 0.24 : 0
        applyTextShadow(look == .clear)
        separator.isHidden = overlay
        capsule.showsBackdropButton = overlay
        capsule.pinned = !overlay
        needsLayout = true
    }

    /// On the clear backdrop the playlist gets a shadow under its text; a page draws its own, the capsule has its glass.
    private func applyTextShadow(_ on: Bool) {
        let shadowed = on && !(shownView is PluginPanel)
        contentHost.layer?.shadowColor = NSColor.black.cgColor
        contentHost.layer?.shadowOpacity = shadowed ? 0.9 : 0
        contentHost.layer?.shadowRadius = 1.5
        contentHost.layer?.shadowOffset = CGSize(width: 0, height: -1)
    }

    override func layout() {
        super.layout()
        let m = SlotCapsuleView.margin, h = SlotCapsuleView.height
        let place = CGRect(x: m, y: panel.bounds.maxY - m - h, width: max(0, panel.bounds.width - 2 * m), height: h)
        if capsule.frame != place { capsule.frame = place }
        // The card's shadow follows its rounded shape (a path: no offscreen pass while it moves).
        layer?.shadowPath = mode == .overlay
            ? CGPath(roundedRect: panel.frame, cornerWidth: Self.overlayCornerRadius,
                     cornerHeight: Self.overlayCornerRadius, transform: nil)
            : nil
    }

    // MARK: Showing and hiding

    /// Slides in from the slot's edge and back out on the same spring (`SlotMotion`: 0.25 s, about 1 % past the mark,
    /// as Zen's compact sidebar); with Reduce Motion a short fade instead. Only this view's layer animates.
    func setShown(_ shown: Bool, animated: Bool, completion: (() -> Void)? = nil) {
        isShown = shown
        if shown { capsule.setVisible(true, animated: false) }   // Task 8: the capsule's own clock
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
            fade.duration = SlotMotion.fade
            animation = fade
        } else {
            let keyPath = edge == .bottom ? "transform.translation.y" : "transform.translation.x"
            let away: CGFloat = switch edge {
            case .left: -bounds.width
            case .right: bounds.width
            case .bottom: -bounds.height
            }
            let spring = CASpringAnimation(keyPath: keyPath)
            spring.mass = SlotMotion.mass
            spring.stiffness = SlotMotion.stiffness
            spring.damping = SlotMotion.damping
            spring.fromValue = shown ? away : 0
            spring.toValue = shown ? 0 : away
            spring.duration = spring.settlingDuration
            animation = spring
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
