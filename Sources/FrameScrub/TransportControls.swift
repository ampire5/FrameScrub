import AppKit
import HomeChrome
import FrameScrubCore

/// Floating viewing controls. The parent owns reveal timing; every input stays in the capsule.
final class TransportControls: NSView, NSPopoverDelegate {
    var onPlay: (() -> Void)?
    var onBack: (() -> Void)?
    var onForward: (() -> Void)?
    var onToggleMute: (() -> Void)?
    var onVolume: ((Double) -> Void)?
    var onSpeed: ((Double) -> Void)?
    var onFullscreen: (() -> Void)?
    var onHold: (() -> Void)?
    static let width: CGFloat = 246
    private let plate = TransportControls.plate()
    private let separator = NSView()
    private let play = TransportControls.button("play.fill", "Play / pause (Space)")
    private let back = TransportControls.button("gobackward.10", "Back 10 seconds")
    private let forward = TransportControls.button("goforward.10", "Forward 10 seconds")
    private let mute = TransportControls.button("speaker.wave.2.fill", "Mute")
    private let volume = TransportControls.button("chevron.down", "Volume")
    private let speed = NSButton(title: "1×", target: nil, action: nil)
    private let full = TransportControls.button("arrow.up.left.and.arrow.down.right", "Enter Full Screen")
    private let slider = NSSlider(value: 100, minValue: 0, maxValue: 100, target: nil, action: nil)
    private let popover = NSPopover()
    private var menuOpen = false
    private var paused: Bool?
    private var level: Int?
    private var muted: Bool?
    private var rate: Double?
    private var feedbackButton: NSButton?
    private var feedbackExpiry: DispatchWorkItem?
    var holding: Bool { menuOpen || popover.isShown }
    /// Actual capsule bounds in the timeline's coordinates.
    var occupiedRects: [NSRect] {
        guard let host = superview else { return [] }
        return [plate.convert(plate.bounds, to: host)]
    }

    init() {
        super.init(frame: .zero)
        Chrome.Palette.overMedia.apply(to: self)
        addSubview(plate)
        separator.wantsLayer = true
        separator.layer?.backgroundColor = Chrome.Palette.overMedia.separator.cgColor
        plate.addSubview(separator)
        for button in [back, play, forward, mute, volume, speed, full] { plate.addSubview(button) }
        let actions: [(NSButton, Selector)] = [(back, #selector(backClicked)), (play, #selector(playClicked)),
            (forward, #selector(forwardClicked)), (mute, #selector(muteClicked)), (volume, #selector(volumeClicked)),
            (speed, #selector(speedClicked)), (full, #selector(fullClicked))]
        for (button, action) in actions { button.target = self; button.action = action; button.refusesFirstResponder = true }
        play.wantsLayer = true
        play.layer?.cornerRadius = Chrome.Radius.photo
        play.layer?.cornerCurve = .continuous
        play.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
        speed.isBordered = false
        speed.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        speed.contentTintColor = Chrome.Palette.overMedia.text
        speed.toolTip = "Playback speed"
        speed.setAccessibilityLabel("Playback speed")
        volume.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        volume.setAccessibilityHelp("Scroll to adjust volume. Click to open the slider.")
        mute.setAccessibilityHelp("Scroll to adjust volume. Click to toggle mute.")
        slider.target = self; slider.action = #selector(sliderMoved)
        slider.isContinuous = true; slider.refusesFirstResponder = true
        slider.setAccessibilityLabel("Volume")
        let controller = NSViewController()
        controller.view = NSView(frame: NSRect(x: 0, y: 0, width: 154, height: 44))
        slider.frame = NSRect(x: 12, y: 12, width: 130, height: 20)
        controller.view.addSubview(slider)
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.delegate = self
    }
    required init?(coder: NSCoder) { fatalError("not used") }
    isolated deinit { feedbackExpiry?.cancel() }

    override func layout() {
        super.layout()
        plate.frame = bounds
        // Keep every control reachable if a pinned slot leaves less than the preferred width.
        let scale = bounds.width / Self.width
        func position(_ x: CGFloat, _ width: CGFloat) -> NSRect {
            NSRect(x: (x * scale).rounded(), y: 3, width: (width * scale).rounded(.down), height: 28)
        }
        for (i, button) in [back, play, forward].enumerated() { button.frame = position(5 + CGFloat(i * 30), 28) }
        separator.frame = NSRect(x: (98 * scale).rounded(), y: 8, width: 1, height: 18)
        mute.frame = position(105, 28)
        volume.frame = position(133, 36)
        speed.frame = position(172, 40)
        full.frame = position(213, 28)
    }

    /// A seek can flash its own button while the capsule is visible.
    func acknowledgeSeek(seconds: Double) {
        let button = seconds < 0 ? back : forward
        clearFeedback()
        button.wantsLayer = true
        button.layer?.cornerRadius = Chrome.Radius.photo
        button.layer?.backgroundColor = Chrome.Palette.overMedia.pressed.cgColor
        feedbackButton = button
        let work = DispatchWorkItem { [weak self] in self?.clearFeedback() }
        feedbackExpiry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55, execute: work)
    }

    private func clearFeedback() {
        feedbackExpiry?.cancel(); feedbackExpiry = nil
        feedbackButton?.layer?.backgroundColor = nil
        feedbackButton = nil
    }
    func update(volume value: Double, muted: Bool, paused: Bool, speed: Double) {
        if self.paused != paused {
            let action = paused ? "Play" : "Pause"
            play.image = Self.image(paused ? "play.fill" : "pause.fill", action)
            play.setAccessibilityLabel(action)
            play.toolTip = action
            self.paused = paused
        }
        let level = Int(value.rounded())
        if slider.doubleValue != value { slider.doubleValue = value }
        if self.level != level || self.muted != muted {
            mute.image = Self.image(muted ? "speaker.slash.fill" : Feedback.volume(level).symbolName, muted ? "Unmute" : "Mute")
            mute.setAccessibilityLabel(muted ? "Unmute" : "Mute")
            mute.toolTip = muted ? "Unmute" : "Mute"
            self.level = level; self.muted = muted
        }
        if rate != speed {
            let title = String(format: "%g×", speed)
            self.speed.title = title
            self.speed.setAccessibilityLabel("Playback speed, \(title)")
            rate = speed
        }
    }

    func updateFullscreen(_ fullscreen: Bool) {
        let action = fullscreen ? "Exit Full Screen" : "Enter Full Screen"
        full.image = Self.image(fullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right", action)
        full.toolTip = action
        full.setAccessibilityLabel(action)
    }
    private static func plate() -> NSView {
        let glass = NSVisualEffectView()
        glass.material = .hudWindow; glass.blendingMode = .withinWindow; glass.state = .active
        glass.wantsLayer = true; glass.layer?.cornerRadius = 12
        glass.layer?.borderWidth = 1
        glass.layer?.borderColor = Chrome.Palette.overMedia.rim.cgColor
        glass.layer?.cornerCurve = .continuous
        glass.layer?.masksToBounds = true
        let veil = NSView(frame: glass.bounds); veil.wantsLayer = true
        veil.layer?.backgroundColor = Chrome.Palette.overMedia.glassTint.cgColor
        veil.autoresizingMask = [.width, .height]
        glass.addSubview(veil)
        return glass
    }
    private static func image(_ symbol: String, _ label: String) -> NSImage {
        Icons.symbol(symbol, pointSize: 14, weight: .medium, description: label) ?? NSImage()
    }
    private static func button(_ symbol: String, _ label: String) -> NSButton {
        let button = NSButton(image: image(symbol, label), target: nil, action: nil)
        button.isBordered = false; button.contentTintColor = Chrome.Palette.overMedia.text
        button.toolTip = label; button.setAccessibilityLabel(label)
        return button
    }
    @objc private func playClicked() { onPlay?() }
    @objc private func backClicked() { onBack?() }
    @objc private func forwardClicked() { onForward?() }
    @objc private func muteClicked() { onToggleMute?() }
    @objc private func fullClicked() { onFullscreen?() }
    @objc private func sliderMoved() { onVolume?(slider.doubleValue) }
    @objc private func volumeClicked() {
        if popover.isShown { popover.performClose(nil); return }
        popover.show(relativeTo: volume.bounds, of: volume, preferredEdge: .maxY)
        onHold?()
    }
    func popoverDidClose(_ notification: Notification) { onHold?() }
    @objc private func speedClicked() {
        menuOpen = true; onHold?()
        defer { menuOpen = false; onHold?() }
        let menu = NSMenu()
        for value in [0.5, 0.75, 1, 1.25, 1.5, 2.0] {
            let item = NSMenuItem(title: String(format: "%g×", value), action: #selector(speedPicked(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = value; item.state = value == rate ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: speed.bounds.maxY), in: speed)
    }
    @objc private func speedPicked(_ item: NSMenuItem) { if let value = item.representedObject as? Double { onSpeed?(value) } }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard alphaValue > 0.01, let hit = super.hitTest(point), hit !== self else { return nil }
        return hit
    }
    override func mouseDown(with event: NSEvent) {}
    override func mouseDragged(with event: NSEvent) {}
    private func isOverVolume(_ point: NSPoint) -> Bool {
        let point = plate.convert(point, from: self)
        return mute.frame.contains(point) || volume.frame.contains(point)
    }

    @discardableResult func adjustVolume(by delta: Double, at point: NSPoint, precise: Bool) -> Bool {
        guard isOverVolume(point) else { return false }
        if delta.isFinite, delta != 0 {
            let change = precise ? delta * 0.2 : delta * 2
            onVolume?(min(slider.maxValue, max(slider.minValue, slider.doubleValue + change)))
        }
        return true
    }

    func handleVolumeScroll(_ event: NSEvent) -> Bool {
        let point = convert(event.locationInWindow, from: nil)
        guard alphaValue > 0.01, isOverVolume(point) else { return false }
        let delta = event.scrollingDeltaY
        if event.momentumPhase.isEmpty, abs(delta) >= abs(event.scrollingDeltaX) {
            adjustVolume(by: delta, at: point, precise: event.hasPreciseScrollingDeltas)
        }
        return true
    }

    override func scrollWheel(with event: NSEvent) { handleVolumeScroll(event) }
}
