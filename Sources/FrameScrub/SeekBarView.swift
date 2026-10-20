import AppKit

/// Bottom bar: track (thicker while pointed at), cached ranges, the A-B range, the previewed frame, playhead and a
/// time label. Click or drag to seek; scrolls over it go to `onScroll` (the preview's keyframe steps).
final class SeekBarView: NSView {
    var onSeek: ((Double) -> Void)?
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
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
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
        hovering = alphaValue > 0.01
        if hovering { onHover?(fraction(event)) }
    }

    override func mouseEntered(with event: NSEvent) { onEnterExit?() }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        onHover?(nil)
        onEnterExit?()
    }

    private func seek(_ event: NSEvent) { onSeek?(fraction(event)) }
}
