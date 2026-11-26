import AppKit
import HomeChrome
import FrameScrubCore

/// Brief transport feedback at the video edge. Repeat actions update the same indicator in place.
final class FeedbackHUD: NSView {
    private let stack = NSView()
    private let icon = NSImageView()
    private let caption = NSTextField(labelWithString: "")
    private var placement = Feedback.Placement.center
    private var hideWork: DispatchWorkItem?
    var bottomClearance: CGFloat = 8 {
        didSet {
            if oldValue != bottomClearance, stack.alphaValue > 0 { needsLayout = true }
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        stack.wantsLayer = true
        stack.alphaValue = 0
        stack.layer?.cornerCurve = .continuous
        stack.layer?.backgroundColor = NSColor(white: 0.06, alpha: 0.88).cgColor
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(white: 0, alpha: 0.45)
        shadow.shadowBlurRadius = 3
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        stack.shadow = shadow
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.contentTintColor = NSColor(white: 1, alpha: 0.9)
        caption.textColor = NSColor(white: 1, alpha: 0.9)
        caption.alignment = .center
        addSubview(stack)
        stack.addSubview(icon)
        stack.addSubview(caption)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        let prominent = placement == .center
        let size = caption.stringValue.isEmpty ? .zero : caption.intrinsicContentSize
        let padding: CGFloat = prominent ? 15 : 7
        let iconWidth: CGFloat = prominent ? 24 : 15
        let height: CGFloat = prominent ? 46 : 24
        let gap: CGFloat = size.width > 0 ? (prominent ? 8 : 4) : 0
        let contentWidth = iconWidth + gap + size.width
        let width = max(contentWidth + 2 * padding, prominent && size.width > 0 ? 110 : 0)
        let x: CGFloat = switch placement {
        case .leading: 12
        case .center: ((bounds.width - width) / 2).rounded()
        case .trailing: max(8, bounds.width - width - 12)
        }
        let y = min(max(bottomClearance, prominent ? 24 : 8), max(0, bounds.height - height))
        let iconX = ((width - contentWidth) / 2).rounded()
        let captionX = iconX + iconWidth + gap
        stack.frame = NSRect(x: x, y: y, width: width, height: height)
        stack.layer?.cornerRadius = prominent ? 12 : 7
        icon.frame = NSRect(x: iconX, y: ((height - iconWidth) / 2).rounded(), width: iconWidth, height: iconWidth)
        caption.frame = NSRect(x: captionX, y: ((height - size.height) / 2).rounded(), width: size.width, height: size.height)
    }

    /// Shows `feedback`, then fades out; `hold: true` keeps it until the next `show` or `hide`.
    func show(_ feedback: Feedback, hold: Bool = false) {
        let prominent = feedback.placement == .center
        icon.image = Icons.symbol(feedback.symbolName, pointSize: prominent ? 22 : 13, weight: .medium)
        caption.font = .monospacedDigitSystemFont(ofSize: prominent ? 18 : 12, weight: prominent ? .semibold : .medium)
        if case let .seek(seconds) = feedback { caption.stringValue = String(format: "%+.3g s", seconds) }
        else { caption.stringValue = feedback.caption ?? "" }
        placement = feedback.placement
        needsLayout = true
        layoutSubtreeIfNeeded()
        hideWork?.cancel()
        if stack.alphaValue < 0.99 {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Chrome.Motion.duration(0.08)
                stack.animator().alphaValue = 1
            }
        }
        guard !hold else { return }
        let work = DispatchWorkItem { [weak self] in self?.fade() }
        hideWork = work
        let dwell = prominent ? 0.7 : 0.45
        DispatchQueue.main.asyncAfter(deadline: .now() + dwell, execute: work)
    }

    func hide() {
        hideWork?.cancel()
        fade()
    }

    private func fade() {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Chrome.Motion.duration(0.16)
            stack.animator().alphaValue = 0
        }
    }
}
