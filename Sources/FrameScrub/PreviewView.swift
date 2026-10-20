import AppKit
import FrameScrubCore

/// The thumbnail, the keyframe lens and the timecode above the seek bar. Never takes clicks.
final class PreviewView: NSView {
    private let imageView = NSImageView()
    private let lensView = KeyframeLensView()
    private let label = NSTextField(labelWithString: "")
    private let stack = NSStackView()
    private var lensWidth: NSLayoutConstraint!

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0, alpha: 0.75).cgColor
        layer?.cornerRadius = 6
        imageView.imageScaling = .scaleNone
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 3
        imageView.layer?.masksToBounds = true
        label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        label.textColor = .white
        stack.orientation = .vertical
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
        stack.addArrangedSubview(imageView)
        stack.addArrangedSubview(lensView)
        stack.addArrangedSubview(label)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        lensWidth = lensView.widthAnchor.constraint(equalToConstant: Self.lensWidthWithoutImage)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            lensWidth, lensView.heightAnchor.constraint(equalToConstant: 14),
        ])
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Points; the lens without a thumbnail (`preview=no`, or before the first one is decoded).
    private static let lensWidthWithoutImage: CGFloat = 240

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// `image` is in physical pixels; `scale` is the window's backing scale. A nil image shows the lens and timecode
    /// only, a nil lens (no keyframes known yet) the rest.
    func show(image: CGImage?, scale: CGFloat, time: String, lens: KeyframeLens?, playhead: Int) {
        if let image {
            let size = NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
            imageView.image = NSImage(cgImage: image, size: size)
            imageView.isHidden = false
            lensWidth.constant = size.width
        } else {
            imageView.image = nil
            imageView.isHidden = true
            lensWidth.constant = Self.lensWidthWithoutImage
        }
        lensView.lens = lens
        lensView.playhead = playhead
        lensView.isHidden = lens == nil
        label.stringValue = time
        isHidden = false
    }

    func hide() { isHidden = true }
}

/// A stretch of the file around the previewed frame: keyframes as ticks, the previewed frame in the middle, the
/// playhead as a dot when it is inside.
private final class KeyframeLensView: NSView {
    var lens: KeyframeLens? { didSet { if lens != oldValue { needsDisplay = true } } }
    var playhead = 0 { didSet { if playhead != oldValue { needsDisplay = true } } }

    override func draw(_ dirtyRect: NSRect) {
        guard let lens else { return }
        let width = bounds.width - 4
        // The previewed frame sits in the middle; frames are spread evenly over ±span, so near the file's ends the
        // stretch is cut off instead of moving the middle.
        let half = Double(max(lens.frame - lens.range.lowerBound, lens.range.upperBound - lens.frame, 1))
        func x(_ frame: Int) -> CGFloat { 2 + width * CGFloat((Double(frame - lens.frame) / half + 1) / 2) }
        let mid = bounds.midY
        NSColor(white: 1, alpha: 0.25).setFill()
        NSRect(x: x(lens.range.lowerBound), y: mid - 0.5, width: x(lens.range.upperBound) - x(lens.range.lowerBound), height: 1).fill()
        NSColor(white: 1, alpha: 0.8).setFill()
        for keyframe in lens.keyframes {
            NSRect(x: x(keyframe).rounded() - 0.5, y: mid - 4, width: 1, height: 8).fill()
        }
        if lens.range.contains(playhead) {
            NSColor.white.setFill()
            NSBezierPath(ovalIn: NSRect(x: x(playhead) - 3, y: mid - 3, width: 6, height: 6)).fill()
        }
        NSColor.white.setFill()
        NSRect(x: x(lens.frame).rounded() - 1, y: bounds.minY, width: 2, height: bounds.height).fill()
    }
}
