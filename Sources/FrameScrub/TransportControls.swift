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
    private let left = TransportControls.plate()
    private let right = TransportControls.plate()
    private let play = TransportControls.button("play.fill", "Play / pause (Space)")
    private let back = TransportControls.button("gobackward.10", "Back 10 seconds")
    private let forward = TransportControls.button("goforward.10", "Forward 10 seconds")
    private let mute = TransportControls.button("speaker.wave.2.fill", "Mute")
    private let volume = TransportControls.button("chevron.down", "Volume")
    private let speed = NSButton(title: "1×", target: nil, action: nil)
    private let full = TransportControls.button("arrow.up.left.and.arrow.down.right", "Full screen")
    private let slider = NSSlider(value: 100, minValue: 0, maxValue: 100, target: nil, action: nil)
    private let popover = NSPopover()
    private var menuOpen = false
    private var paused: Bool?
    private var level: Int?
    private var muted: Bool?
    private var rate: Double?
    var holding: Bool { menuOpen || popover.isShown }
    /// Actual capsule bounds in the timeline's coordinates, excluding the transparent space between them.
    var occupiedRects: [NSRect] {
        guard let host = superview else { return [] }
        return [left, right].map { $0.convert($0.bounds, to: host) }
    }

    init() {
        super.init(frame: .zero)
        appearance = NSAppearance(named: .darkAqua)
        for view in [left, right] { addSubview(view) }
        for button in [back, play, forward] { left.addSubview(button) }
        for button in [mute, volume, speed, full] { right.addSubview(button) }
        let actions: [(NSButton, Selector)] = [(back, #selector(backClicked)), (play, #selector(playClicked)),
            (forward, #selector(forwardClicked)), (mute, #selector(muteClicked)), (volume, #selector(volumeClicked)),
            (speed, #selector(speedClicked)), (full, #selector(fullClicked))]
        for (button, action) in actions { button.target = self; button.action = action; button.refusesFirstResponder = true }
        play.wantsLayer = true
        play.layer?.cornerRadius = 14
        play.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
        speed.isBordered = false
        speed.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        speed.contentTintColor = .white
        speed.toolTip = "Playback speed"
        speed.setAccessibilityLabel("Playback speed")
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

    override func layout() {
        super.layout()
        left.frame = NSRect(x: 0, y: 0, width: 100, height: 34)
        right.frame = NSRect(x: max(104, bounds.width - 130), y: 0, width: 130, height: 34)
        for (i, button) in [back, play, forward].enumerated() { button.frame = NSRect(x: 5 + i * 30, y: 3, width: 28, height: 28) }
        mute.frame = NSRect(x: 4, y: 3, width: 28, height: 28)
        volume.frame = NSRect(x: 30, y: 3, width: 18, height: 28)
        speed.frame = NSRect(x: 49, y: 3, width: 43, height: 28)
        full.frame = NSRect(x: 94, y: 3, width: 30, height: 28)
    }
    func update(volume value: Double, muted: Bool, paused: Bool, speed: Double) {
        if self.paused != paused {
            play.image = Self.image(paused ? "play.fill" : "pause.fill", paused ? "Play" : "Pause")
            play.setAccessibilityLabel(paused ? "Play" : "Pause")
            self.paused = paused
        }
        let level = Int(value.rounded())
        if self.level != level || self.muted != muted {
            mute.image = Self.image(muted ? "speaker.slash.fill" : Feedback.volume(level).symbolName, muted ? "Unmute" : "Mute")
            mute.setAccessibilityLabel(muted ? "Unmute" : "Mute")
            mute.toolTip = muted ? "Unmute" : "Mute"
            if !popover.isShown { slider.doubleValue = value }
            self.level = level; self.muted = muted
        }
        if rate != speed { self.speed.title = String(format: "%g×", speed); rate = speed }
    }
    private static func plate() -> NSView {
        let glass = NSVisualEffectView()
        glass.material = .hudWindow; glass.blendingMode = .withinWindow; glass.state = .active
        glass.wantsLayer = true; glass.layer?.cornerRadius = 17; glass.layer?.masksToBounds = true
        let veil = NSView(); veil.wantsLayer = true
        veil.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.35).cgColor
        veil.autoresizingMask = [.width, .height]
        glass.addSubview(veil)
        return glass
    }
    private static func image(_ symbol: String, _ label: String) -> NSImage {
        Icons.symbol(symbol, pointSize: 13, weight: .medium, description: label) ?? NSImage()
    }
    private static func button(_ symbol: String, _ label: String) -> NSButton {
        let button = NSButton(image: image(symbol, label), target: nil, action: nil)
        button.isBordered = false; button.contentTintColor = NSColor(white: 1, alpha: 0.88)
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
    override func scrollWheel(with event: NSEvent) {}
}
