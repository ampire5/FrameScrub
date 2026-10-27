import AppKit
import FrameScrubCore
import HomeChrome

/// Bottom bar: track (thicker while pointed at), cached ranges, the A-B range, the previewed frame, playhead and a
/// time label, with the transport controls (previous / next item, mute and volume) at the right under the track.
/// Click or drag to seek; scrolls over it go to `onScroll` (the preview's keyframe steps). The controls keep their
/// clicks and scrolls: none reaches the track or the video.
final class SeekBarView: NSView {
    var onSeek: ((Double) -> Void)?
    /// The controls; set by the window, and their state by `updateTransport`.
    let transport = TransportControls()
    private var frameCount = 0
    private var position = 0
    private var cached: [ClosedRange<Int>] = []
    private var loopA: Int?
    private var loopB: Int?
    /// Cut marks (green), the lead-ins their clips get from keyframes (fainter), and an open mark's start.
    private var marks: [ClosedRange<Int>] = []
    private var leadIns: [ClosedRange<Int>] = []
    private var openMark: Int?
    /// The frame the preview shows while the pointer is on the bar; marked on the track.
    var previewFrame: Int? { didSet { if previewFrame != oldValue { needsDisplay = true } } }
    private var hovering = false { didSet { if hovering != oldValue { needsDisplay = true } } }
    private let label = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0, alpha: 0.55).cgColor
        layer?.cornerRadius = 8
        label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        label.textColor = .white
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)   // a narrow window cuts the text, not the controls
        label.translatesAutoresizingMaskIntoConstraints = false
        transport.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        addSubview(transport)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
            label.trailingAnchor.constraint(lessThanOrEqualTo: transport.leadingAnchor, constant: -12),
            transport.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            transport.centerYAnchor.constraint(equalTo: label.centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(frameCount: Int, position: Int, cached: [ClosedRange<Int>], loopA: Int?, loopB: Int?,
                marks: [ClosedRange<Int>] = [], leadIns: [ClosedRange<Int>] = [], openMark: Int? = nil, text: String) {
        self.frameCount = frameCount
        self.position = position
        self.cached = cached
        self.loopA = loopA
        self.loopB = loopB
        self.marks = marks
        self.leadIns = leadIns
        self.openMark = openMark
        label.stringValue = text
        needsDisplay = true
    }

    /// 6 points high, 10 while pointed at, around the same middle.
    private var track: NSRect {
        hovering ? NSRect(x: 12, y: bounds.height - 18, width: bounds.width - 24, height: 10)
            : NSRect(x: 12, y: bounds.height - 16, width: bounds.width - 24, height: 6)
    }

    private func x(for frame: Int) -> CGFloat {
        track.minX + track.width * CGFloat(frame) / CGFloat(max(frameCount - 1, 1))
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 1, alpha: 0.25).setFill()
        NSBezierPath(roundedRect: track, xRadius: track.height / 2, yRadius: track.height / 2).fill()
        NSColor.systemTeal.withAlphaComponent(0.85).setFill()
        for range in cached {
            NSRect(x: x(for: range.lowerBound), y: track.minY,
                   width: max(1, x(for: range.upperBound) - x(for: range.lowerBound)), height: track.height).fill()
        }
        func fill(_ range: ClosedRange<Int>) {
            NSRect(x: x(for: range.lowerBound), y: track.minY,
                   width: max(1, x(for: range.upperBound) - x(for: range.lowerBound)), height: track.height).fill()
        }
        NSColor.systemGreen.withAlphaComponent(0.3).setFill()
        leadIns.forEach(fill)
        NSColor.systemGreen.withAlphaComponent(0.65).setFill()
        marks.forEach(fill)
        if let open = openMark {
            NSColor.systemGreen.withAlphaComponent(0.35).setFill()
            fill(min(open, position)...max(open, position))
            NSColor.systemGreen.withAlphaComponent(0.9).setFill()
            NSRect(x: x(for: open) - 1, y: track.minY - 2, width: 2, height: track.height + 4).fill()
        }
        if let a = loopA, let b = loopB {
            NSColor.systemYellow.withAlphaComponent(0.35).setFill()
            NSRect(x: x(for: min(a, b)), y: track.minY - 2, width: max(1, abs(x(for: b) - x(for: a))), height: track.height + 4).fill()
        }
        if hovering, let previewFrame {
            NSColor(white: 1, alpha: 0.9).setFill()
            NSRect(x: x(for: previewFrame).rounded() - 1, y: track.minY - 3, width: 2, height: track.height + 6).fill()
        }
        NSColor.systemYellow.setFill()
        for marker in [loopA, loopB].compactMap({ $0 }) {
            NSRect(x: x(for: marker) - 1, y: track.minY - 4, width: 2, height: track.height + 8).fill()
        }
        NSColor.white.setFill()
        let head = x(for: position)
        NSBezierPath(ovalIn: NSRect(x: head - 5, y: track.midY - 5, width: 10, height: 10)).fill()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        alphaValue > 0.01 ? super.hitTest(point) : nil
    }

    override func mouseDown(with event: NSEvent) { seek(event) }
    override func mouseDragged(with event: NSEvent) { seek(event) }

    var onHover: ((Double?) -> Void)?
    var onScroll: ((NSEvent) -> Void)?
    /// The pointer came onto the bar or left it (even while the bar is faded out).
    var onEnterExit: (() -> Void)?

    override func scrollWheel(with event: NSEvent) { onScroll?(event) }

    private func fraction(_ event: NSEvent) -> Double {
        let point = convert(event.locationInWindow, from: nil)
        return min(max(Double((point.x - track.minX) / track.width), 0), 1)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        let overControls = transport.frame.insetBy(dx: -4, dy: -4).contains(convert(event.locationInWindow, from: nil))
        let wasHovering = hovering
        hovering = alphaValue > 0.01 && !overControls
        if hovering { onHover?(fraction(event)) } else if wasHovering { onHover?(nil) }   // onto the controls: no preview
    }

    override func mouseEntered(with event: NSEvent) { onEnterExit?() }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        onHover?(nil)
        onEnterExit?()
    }

    private func seek(_ event: NSEvent) { onSeek?(fraction(event)) }
}

/// ⏮ ⏭ and the volume (mute button and slider) on the seek bar. Clicks between the controls, scrolls and drags stay
/// here; the controls never take the keyboard (keys go on to the player). Shown state changes only when it differs:
/// the window refreshes it on every player update.
final class TransportControls: NSView {
    var onPrevious: (() -> Void)?
    var onNext: (() -> Void)?
    var onToggleMute: (() -> Void)?
    /// The slider moved: 0…100.
    var onVolume: ((Double) -> Void)?

    private let previous = TransportControls.button("backward.end.fill", label: "Previous item")
    private let next = TransportControls.button("forward.end.fill", label: "Next item")
    private let mute = TransportControls.button("speaker.wave.3.fill", label: "Mute")
    private let slider = NSSlider(value: 100, minValue: 0, maxValue: 100, target: nil, action: nil)
    private var shown: (previous: Bool, next: Bool, volume: Int, muted: Bool)?

    private static let tint = NSColor(white: 1, alpha: 0.9)
    private static let dimmed = NSColor(white: 1, alpha: 0.3)

    init() {
        super.init(frame: .zero)
        appearance = NSAppearance(named: .darkAqua)   // light controls on the bar's dark plate, whatever the system's
        previous.target = self
        previous.action = #selector(previousClicked)
        next.target = self
        next.action = #selector(nextClicked)
        mute.target = self
        mute.action = #selector(muteClicked)
        slider.target = self
        slider.action = #selector(sliderMoved)
        slider.controlSize = .mini
        slider.isContinuous = true
        slider.refusesFirstResponder = true
        slider.trackFillColor = Self.tint
        slider.toolTip = "Volume"
        slider.setAccessibilityLabel("Volume")
        let views: [NSView] = [previous, next, mute, slider]
        for view in views {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 22),
            previous.leadingAnchor.constraint(equalTo: leadingAnchor),
            next.leadingAnchor.constraint(equalTo: previous.trailingAnchor, constant: 2),
            mute.leadingAnchor.constraint(equalTo: next.trailingAnchor, constant: 14),
            slider.leadingAnchor.constraint(equalTo: mute.trailingAnchor, constant: 2),
            slider.trailingAnchor.constraint(equalTo: trailingAnchor),
            slider.widthAnchor.constraint(equalToConstant: 76),
            slider.centerYAnchor.constraint(equalTo: centerYAnchor),
        ] + [previous, next, mute].flatMap { button in [
            button.widthAnchor.constraint(equalToConstant: 26),
            button.heightAnchor.constraint(equalToConstant: 22),
            button.centerYAnchor.constraint(equalTo: centerYAnchor),
        ] })
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private static func button(_ symbol: String, label: String) -> NSButton {
        let button = NSButton(image: image(symbol, label: label), target: nil, action: nil)
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleNone
        button.contentTintColor = tint
        button.refusesFirstResponder = true
        button.toolTip = label
        button.setAccessibilityLabel(label)
        return button
    }

    private static func image(_ symbol: String, label: String) -> NSImage {
        Lucide.icon(symbol, pointSize: 12, weight: .medium, description: label) ?? NSImage()
    }

    /// What the controls show: whether there is an item before / after, the volume (0…100) and mute.
    func update(hasPrevious: Bool, hasNext: Bool, volume: Double, muted: Bool) {
        let state = (previous: hasPrevious, next: hasNext, volume: Int(volume.rounded()), muted: muted)
        if let shown, shown == state { return }
        if shown?.previous != state.previous { Self.enable(previous, state.previous) }
        if shown?.next != state.next { Self.enable(next, state.next) }
        if shown?.volume != state.volume || shown?.muted != state.muted {
            let label = muted ? "Unmute" : "Mute"
            // The speaker's waves as many as the level's (Lucide has no variable symbols): as the volume HUD's.
            mute.image = Self.image(muted ? "speaker.slash.fill" : Feedback.volume(state.volume).symbolName, label: label)
            mute.toolTip = label
            mute.setAccessibilityLabel(label)
            if slider.integerValue != state.volume { slider.doubleValue = Double(state.volume) }
            slider.alphaValue = muted ? 0.45 : 1   // the level stays where it was, dimmed: moving it unmutes
        }
        shown = state
    }

    private static func enable(_ button: NSButton, _ on: Bool) {
        button.isEnabled = on
        button.contentTintColor = on ? tint : dimmed
    }

    @objc private func previousClicked() { onPrevious?() }
    @objc private func nextClicked() { onNext?() }
    @objc private func muteClicked() { onToggleMute?() }
    @objc private func sliderMoved() { onVolume?(slider.doubleValue) }

    // Between and around the controls: nothing reaches the bar under them (a seek) or the video.
    override func mouseDown(with event: NSEvent) {}
    override func mouseDragged(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}
    override func otherMouseDown(with event: NSEvent) {}
    override func scrollWheel(with event: NSEvent) {}
}
