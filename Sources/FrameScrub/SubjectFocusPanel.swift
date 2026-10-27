import AppKit
import FrameScrubCore

/// Subject Focus's panel (spike; the mockup "Subject Focus panel"): on/off and the style for its window, the look's
/// sliders (a change makes the style Custom), the edge, and the mask's settings shared by the windows
/// (`SubjectFocusSettings`). It lives in a slot (⌥H, View › Subject Focus › Panel, a slot's menu), which brings the
/// edge, the backdrop and hiding; the text is light on any backdrop (the slots' backdrops are dark). Built once, when
/// first shown, and kept.
@MainActor final class SubjectFocusPanelView: NSView {
    /// The window's style; nil: off.
    var currentStyle: () -> SubjectFocusStyle? = { nil }
    /// Turns the window's effect on in a style, or off.
    var setStyle: (SubjectFocusStyle?) -> Void = { _ in }
    /// The style `H` turns on.
    var lastStyle: () -> SubjectFocusStyle = { .studio }

    private static let primary = NSColor(srgbRed: 0xf2 / 255, green: 0xf2 / 255, blue: 0xf7 / 255, alpha: 1)
    private static let secondary = NSColor(srgbRed: 0x9a / 255, green: 0x9a / 255, blue: 0xa2 / 255, alpha: 1)

    private let onSwitch = NSSwitch()
    private var styleButtons: [SubjectFocusStyle: NSButton] = [:]
    private var sliders: [Slider] = []
    private let cleanEdge = NSSwitch()
    private let mask = NSSegmentedControl(labels: ["RVM", "Vision"], trackingMode: .selectOne, target: nil, action: nil)
    private let maskNote = NSTextField(wrappingLabelWithString: "")
    private let quality = NSSegmentedControl(labels: ["Fast", "Balanced", "Accurate"], trackingMode: .selectOne,
                                             target: nil, action: nil)
    private let steadiness = NSSlider(value: 0.6, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let steadinessValue = NSTextField(labelWithString: "")
    private let stillAccurate = NSSwitch()
    private let who = NSSegmentedControl(labels: ["All people", "Main people"], trackingMode: .selectOne, target: nil, action: nil)
    private let showMask = NSSwitch()
    private var built = false
    private var observer: NSObjectProtocol?

    /// One slider of the look: its row's value text and how it reads and writes the look.
    private struct Slider {
        let control: NSSlider
        let value: NSTextField
        let get: (SubjectFocusStyle.Look) -> Double
        let set: (inout SubjectFocusStyle.Look, Double) -> Void
        let text: (Double) -> String
    }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 340, height: 600))
        appearance = NSAppearance(named: .darkAqua)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Builds the controls the first time (before the slot puts the view in a window: no layout per control) and shows
    /// the current values.
    func prepare() {
        if !built {
            built = true
            build()
            observer = NotificationCenter.default.addObserver(forName: SubjectFocusSettings.changed, object: nil,
                                                              queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
        refresh()
    }

    // MARK: Building

    private func build() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false

        // on / off
        let subtitle = label("People stay, the background changes", secondary: true)
        onSwitch.target = self
        onSwitch.action = #selector(toggleOn)
        stack.addArrangedSubview(row(label("On  (H)"), onSwitch, under: subtitle))

        // the styles, 3 × 2
        let grid = NSGridView(numberOfColumns: 3, rows: 0)
        grid.columnSpacing = 6
        grid.rowSpacing = 6
        let styles = SubjectFocusStyle.allCases
        for start in stride(from: 0, to: styles.count, by: 3) {
            grid.addRow(with: styles[start..<min(styles.count, start + 3)].map { style in
                let b = NSButton(title: style.title, target: self, action: #selector(pickStyle(_:)))
                b.setButtonType(.pushOnPushOff)
                b.bezelStyle = .push
                b.controlSize = .regular
                b.tag = styles.firstIndex(of: style)!
                b.translatesAutoresizingMaskIntoConstraints = false
                b.widthAnchor.constraint(equalToConstant: 96).isActive = true
                styleButtons[style] = b
                return b
            })
        }
        stack.addArrangedSubview(section("STYLE  ·  ⇧H NEXT", [grid]))

        // the look
        func pct(_ v: Double) -> String { "\(Int((v * 100).rounded())) %" }
        let background = [
            slider("Brightness (black ↔ white)", -1, 1, { $0.brightness }, { $0.brightness = $1 }) { v in
                let n = Int((v * 100).rounded()); return n > 0 ? "+\(n)" : "\(n)"
            },
            slider("Blur", 0, 1, { $0.blur }, { $0.blur = $1 }, pct),
            slider("Colour", 0, 1, { 1 - $0.desaturate }, { $0.desaturate = 1 - $1 }, pct),
        ]
        stack.addArrangedSubview(section("BACKGROUND", background))
        cleanEdge.target = self
        cleanEdge.action = #selector(changeCleanEdge)
        let edge = [
            slider("Edge softness", 0, 1, { $0.feather }, { $0.feather = $1 }, pct),
            slider("Shrink ↔ grow", -10, 10, { $0.grow }, { $0.grow = $1.rounded() }) { v in
                let n = Int(v.rounded()); return n > 0 ? "+\(n) pt" : "\(n) pt"
            },
            slider("Falloff near people", 0, 1, { $0.falloff }, { $0.falloff = $1 }, pct),
            slider("People contrast", 0, 1, { $0.boost }, { $0.boost = $1 }, pct),
            row(label("Clean edge colour"), cleanEdge),
        ]
        stack.addArrangedSubview(section("EDGE AND PEOPLE", edge))

        // the mask, shared by the windows
        for control in [mask, quality, who] {
            control.target = self
            control.action = #selector(changeMask(_:))
            control.segmentDistribution = .fillEqually
        }
        maskNote.textColor = Self.secondary
        maskNote.font = .systemFont(ofSize: 11)
        maskNote.preferredMaxLayoutWidth = 300
        steadiness.target = self
        steadiness.action = #selector(changeSteadiness)
        steadiness.isContinuous = false   // each step makes the masks again: taken when let go
        steadinessValue.textColor = Self.secondary
        stillAccurate.target = self
        stillAccurate.action = #selector(changeStillAccurate)
        showMask.target = self
        showMask.action = #selector(changeShowMask)
        let qualityRow = NSStackView(views: [label("Vision while playing", secondary: true), quality])
        qualityRow.orientation = .vertical
        qualityRow.alignment = .leading
        qualityRow.spacing = 4
        let steadyRow = NSStackView(views: [row(label("Steadiness (Vision)"), steadinessValue), steadiness])
        steadyRow.orientation = .vertical
        steadyRow.alignment = .leading
        steadyRow.spacing = 4
        let maskViews: [NSView] = [mask, maskNote, qualityRow, steadyRow,
                                   row(label("Sharper mask when paused"), stillAccurate),
                                   row(label("Who"), who), row(label("Show mask"), showMask)]
        stack.addArrangedSubview(section("MASK  ·  EVERY WINDOW", maskViews))

        let reset = NSButton(title: "Reset to Defaults", target: self, action: #selector(resetAll))
        reset.bezelStyle = .push
        stack.addArrangedSubview(reset)

        // the stack scrolls when the slot is short
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = document
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor), scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])
        // every row as wide as the stack
        for case let view as NSStackView in stack.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
        }
    }

    private func label(_ text: String, secondary: Bool = false) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.textColor = secondary ? Self.secondary : Self.primary
        l.font = .systemFont(ofSize: secondary ? 11 : 12)
        return l
    }

    /// A label on the left, a control on the right, and an optional line under them.
    private func row(_ left: NSView, _ right: NSView, under: NSView? = nil) -> NSStackView {
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let line = NSStackView(views: [left, spacer, right])
        line.orientation = .horizontal
        line.alignment = .centerY
        guard let under else { return line }
        let both = NSStackView(views: [line, under])
        both.orientation = .vertical
        both.alignment = .leading
        both.spacing = 2
        line.widthAnchor.constraint(equalTo: both.widthAnchor).isActive = true
        return both
    }

    private func section(_ title: String, _ views: [NSView]) -> NSStackView {
        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 11, weight: .semibold)
        heading.textColor = Self.secondary
        let stack = NSStackView(views: [heading] + views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        for view in views where view is NSStackView || view is NSSlider || view is NSSegmentedControl {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return stack
    }

    private func slider(_ title: String, _ min: Double, _ max: Double, _ get: @escaping (SubjectFocusStyle.Look) -> Double,
                        _ set: @escaping (inout SubjectFocusStyle.Look, Double) -> Void,
                        _ text: @escaping (Double) -> String) -> NSView {
        let control = NSSlider(value: min, minValue: min, maxValue: max, target: self, action: #selector(changeLook(_:)))
        control.isContinuous = true
        control.tag = sliders.count
        let value = label("", secondary: true)
        sliders.append(Slider(control: control, value: value, get: get, set: set, text: text))
        let stack = NSStackView(views: [row(label(title), value), control])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        for view in stack.arrangedSubviews { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        return stack
    }

    // MARK: Values

    /// Shows the window's style and the shared settings.
    func refresh() {
        guard built else { return }
        let settings = SubjectFocusSettings.shared
        let style = currentStyle()
        onSwitch.state = style != nil ? .on : .off
        for (s, b) in styleButtons { b.state = s == style ? .on : .off }
        let look = settings.look(style ?? lastStyle())
        for s in sliders {
            let v = s.get(look)
            if s.control.doubleValue != v { s.control.doubleValue = v }
            s.value.stringValue = s.text(v)
        }
        cleanEdge.state = settings.cleanEdge ? .on : .off
        mask.setEnabled(SubjectMatting.isAvailable, forSegment: 0)
        mask.selectedSegment = settings.matting ? 0 : 1
        quality.selectedSegment = SubjectFocusSettings.VisionQuality.allCases.firstIndex(of: settings.visionQuality)!
        quality.isEnabled = !settings.matting
        steadiness.doubleValue = settings.steadiness
        steadiness.isEnabled = !settings.matting
        steadinessValue.stringValue = settings.steadiness < 0.35 ? "Responsive" : settings.steadiness > 0.7 ? "Steady" : "Balanced"
        stillAccurate.state = settings.stillAccurate ? .on : .off
        who.selectedSegment = settings.mainPeople ? 1 : 0
        showMask.state = settings.showMask ? .on : .off
        maskNote.stringValue = Self.note(settings)
    }

    /// What the chosen mask costs and does (measured: docs/subject-focus-rvm.md, M4 Max, 1080p).
    private static func note(_ settings: SubjectFocusSettings) -> String {
        if settings.matting {
            return "RobustVideoMatting on the Neural Engine: ~6.5 ms a frame, a steady edge, whole hair. "
                + "Paused or scrubbing: its finer model."
        }
        guard SubjectMatting.isAvailable else {
            return "RVM needs its models, prepared once: scripts/rvm/prepare-models.sh (docs/subject-focus-rvm.md).\n"
                + visionNote(settings.visionQuality)
        }
        return visionNote(settings.visionQuality)
    }

    private static func visionNote(_ quality: SubjectFocusSettings.VisionQuality) -> String {
        switch quality {
        case .fast: "Vision fast: the roughest edge."
        case .balanced: "Vision balanced: ~18 ms a frame in the app; the edge flickers more than RVM's."
        case .accurate: "Vision accurate: ~34 ms a frame, too slow for every frame while playing."
        }
    }

    // MARK: Actions

    @objc private func toggleOn() {
        setStyle(currentStyle() == nil ? lastStyle() : nil)
        refresh()
    }

    @objc private func pickStyle(_ sender: NSButton) {
        setStyle(SubjectFocusStyle.allCases[sender.tag])
        refresh()
    }

    /// A slider: the look becomes the custom style's (starting from the style on screen), and the window shows it.
    @objc private func changeLook(_ sender: NSSlider) {
        let settings = SubjectFocusSettings.shared
        let s = sliders[sender.tag]
        let style = currentStyle() ?? lastStyle()
        var look = settings.look(style)
        s.set(&look, sender.doubleValue)
        settings.custom = look
        if currentStyle() != .custom { setStyle(.custom) }
        refresh()
    }

    @objc private func changeCleanEdge() { SubjectFocusSettings.shared.cleanEdge = cleanEdge.state == .on }

    @objc private func changeMask(_ sender: NSSegmentedControl) {
        let settings = SubjectFocusSettings.shared
        switch sender {
        case mask: settings.matting = sender.selectedSegment == 0
        case quality: settings.visionQuality = SubjectFocusSettings.VisionQuality.allCases[sender.selectedSegment]
        default: settings.mainPeople = sender.selectedSegment == 1
        }
    }

    @objc private func changeSteadiness() { SubjectFocusSettings.shared.steadiness = steadiness.doubleValue }
    @objc private func changeStillAccurate() { SubjectFocusSettings.shared.stillAccurate = stillAccurate.state == .on }
    @objc private func changeShowMask() { SubjectFocusSettings.shared.showMask = showMask.state == .on }
    @objc private func resetAll() { SubjectFocusSettings.shared.reset() }

    /// Bench: moves the first slider (the brightness) to `value` as a drag would.
    func benchSlide(to value: Double) {
        guard let s = sliders.first?.control else { return }
        s.doubleValue = value
        s.sendAction(s.action, to: s.target)
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// Subject Focus's panel as an overlay card over the video's right side, apart from the slots (they may all hold
/// plugins): the slots' card (`SlotView`: backdrop, spring in, slide out) and their hiding (`AutoHideClock`): ⌥H or
/// View › Subject Focus › Panel shows it, it goes 150 ms after the pointer left it (overshooting the window's right
/// edge by up to 200 pt still counts as in), and with ⌥H again, ✕ or a click on the video. Nothing runs while hidden.
@MainActor final class SubjectFocusPanelHost {
    let panel = SubjectFocusPanelView()
    /// The band at the container's top the card keeps clear (title bar and toolbar).
    var topInset: () -> CGFloat = { 0 }
    private let container: NSView
    private let card = SlotView(edge: .right)
    private var clock = AutoHideClock(mode: .mouseLeaves)
    private var monitor: Any?
    private var hideTimer: Timer?
    private static let width: CGFloat = 340 + 2 * SlotView.overlayInset
    private static let overshoot: CGFloat = 200
    private static let backdropKey = "SubjectFocus.panelBackdrop"

    init(container: NSView) { self.container = container }

    var isShown: Bool { card.isShown }

    func toggle() { if card.isShown { hide() } else { show() } }

    func show() {
        guard !card.isShown else { return }
        if card.superview == nil {
            panel.prepare()   // the controls are built before the card is in the window
            card.showsSlotMenu = false
            card.title = "Subject Focus"
            card.content = panel
            card.backdrop = UserDefaults.standard.string(forKey: Self.backdropKey).flatMap(SlotBackdrop.init(rawValue:)) ?? .glass
            card.onClose = { [weak self] in self?.hide() }
            card.onCycleBackdrop = { [weak self] in
                guard let self else { return }
                card.backdrop = card.backdrop.next
                UserDefaults.standard.set(card.backdrop.rawValue, forKey: Self.backdropKey)
            }
            card.translatesAutoresizingMaskIntoConstraints = true
            card.autoresizingMask = [.minXMargin, .height]
        } else {
            panel.refresh()
        }
        container.addSubview(card)   // on top of the slots and their tongues
        let b = container.bounds
        card.frame = NSRect(x: b.maxX - Self.width, y: b.minY, width: Self.width, height: max(0, b.height - topInset()))
        card.setShown(true, animated: true)
        clock.shown(pointerInside: pointerInside, now: CACurrentMediaTime())
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            MainActor.assumeIsolated { self?.pointerMoved() }
            return event
        }
    }

    func hide() {
        guard card.isShown else { return }
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        hideTimer?.invalidate()
        hideTimer = nil
        if card.holds(container.window?.firstResponder as? NSView) { container.window?.makeFirstResponder(container) }
        card.setShown(false, animated: true)
    }

    /// In the card, or past the window's right edge beside it (up to `overshoot`).
    private var pointerInside: Bool {
        guard let window = container.window else { return false }
        let p = container.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        let f = card.frame
        return p.x >= f.minX && p.x <= f.maxX + Self.overshoot && p.y >= f.minY && p.y <= f.maxY
    }

    private func pointerMoved() {
        clock.pointerInside(pointerInside, now: CACurrentMediaTime())
        guard hideTimer == nil else { return }
        hideTimer = Timer.scheduledTimer(withTimeInterval: AutoHideClock.mouseLeaveDelay + 0.01, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkHide() }
        }
    }

    /// Bench (`FRAMESCRUB_FOCUS_PANEL=bench`): the main thread's CPU time (`CLOCK_THREAD_CPUTIME_ID`) to show the panel
    /// (the first time builds it), to hide it, and for a slider step, 5 rounds, logged.
    func bench() {
        func cpu() -> Double { var t = timespec(); clock_gettime(CLOCK_THREAD_CPUTIME_ID, &t); return Double(t.tv_sec) * 1e3 + Double(t.tv_nsec) / 1e6 }
        var round = 0
        func step() {
            guard round < 5 else { return }
            round += 1
            var t = cpu(); show(); let shown = cpu() - t
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [self] in
                var slides: [Double] = []
                for k in 0..<10 {
                    t = cpu(); panel.benchSlide(to: -1 + Double(k) * 0.2); slides.append(cpu() - t)
                }
                t = cpu(); hide(); let hidden = cpu() - t
                NSLog("subject focus panel bench: round %d, show %.2f ms, slider step %.2f ms (max %.2f), hide %.2f ms", round,
                      shown, slides.reduce(0, +) / Double(slides.count), slides.max()!, hidden)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { step() }
            }
        }
        step()
    }

    private func checkHide() {
        hideTimer = nil
        guard card.isShown else { return }
        clock.pointerInside(pointerInside, now: CACurrentMediaTime())
        clock.setBusy(NSEvent.pressedMouseButtons != 0)   // a slider held past the card's edge
        if clock.shouldHide(now: CACurrentMediaTime()) { hide() } else if !pointerInside { pointerMoved() }
    }
}
