import AppKit
import FrameScrubCore

/// Transport icons over the video, frameless like QuickTime's: seeks back on the left, forward on the right,
/// play, pause and the rest in the centre. Covers the whole video and never takes clicks. A repeated event
/// updates the icon in place, so holding a key does not make it blink. Sizes and places are fractions of the
/// view, so the icon keeps its proportions in a small window and in full screen.
final class FeedbackHUD: NSView {
    private let stack = NSView()
    private let icon = NSImageView()
    private let caption = NSTextField(labelWithString: "")
    private var placement = Feedback.Placement.center
    private var hideWork: DispatchWorkItem?

    /// Seek icons are 4.8 % of the width wide (as in QuickTime); the centre icons are 7.5 % of the height tall,
    /// a little larger.
    private static let seekWidth: CGFloat = 0.052   // the symbol has a little padding: draws ~4.8 %
    private static let centerHeight: CGFloat = 0.075
    /// Horizontal centre of a seek icon, as a fraction of the width from its side.
    private static let seekInset: CGFloat = 0.245
    /// Vertical centre of the icon, as a fraction of the height from the top (slightly above the middle).
    private static let iconY: CGFloat = 0.47

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        stack.wantsLayer = true
        stack.alphaValue = 0
        // White with a soft shadow reads on dark and bright frames alike, without a plate behind it.
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(white: 0, alpha: 0.75)
        shadow.shadowBlurRadius = 5
        shadow.shadowOffset = .zero
        stack.shadow = shadow
        icon.symbolConfiguration = .init(pointSize: 120, weight: .regular)   // drawn large, scaled down: crisp at any size
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
        let aspect = icon.image.map { $0.size.width / max($0.size.height, 1) } ?? 1
        let height = placement == .center ? (bounds.height * Self.centerHeight).rounded()
            : (bounds.width * Self.seekWidth / aspect).rounded()
        let iconSize = CGSize(width: (height * aspect).rounded(), height: height)
        let fractionX: CGFloat = switch placement {
        case .leading: Self.seekInset
        case .center: 0.5
        case .trailing: 1 - Self.seekInset
        }
        let centerX = bounds.width * fractionX
        let centerY = bounds.height * (1 - Self.iconY)   // AppKit's y grows upwards
        caption.font = .monospacedDigitSystemFont(ofSize: max(11, (height * 0.4).rounded()), weight: .semibold)
        let captionSize = caption.stringValue.isEmpty ? .zero : caption.intrinsicContentSize
        let gap: CGFloat = captionSize == .zero ? 0 : 4
        let width = max(iconSize.width, captionSize.width)
        // The icon stays at its spot; a caption hangs below it.
        stack.frame = CGRect(x: (centerX - width / 2).rounded(),
                             y: (centerY - iconSize.height / 2 - gap - captionSize.height).rounded(),
                             width: width, height: iconSize.height + gap + captionSize.height)
        icon.frame = CGRect(x: ((width - iconSize.width) / 2).rounded(), y: captionSize.height + gap,
                            width: iconSize.width, height: iconSize.height)
        caption.frame = CGRect(x: ((width - captionSize.width) / 2).rounded(), y: 0,
                               width: captionSize.width, height: captionSize.height)
    }

    /// Shows `feedback`, then fades out; `hold: true` keeps it until the next `show` or `hide`.
    func show(_ feedback: Feedback, hold: Bool = false) {
        icon.image = NSImage(systemSymbolName: feedback.symbolName, accessibilityDescription: nil)
        caption.stringValue = feedback.caption ?? ""
        placement = feedback.placement
        needsLayout = true
        layoutSubtreeIfNeeded()
        hideWork?.cancel()
        if stack.alphaValue < 0.99 { appear() }
        guard !hold else { return }
        let work = DispatchWorkItem { [weak self] in self?.fade() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
    }

    func hide() {
        hideWork?.cancel()
        fade()
    }

    private func appear() {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.1
            stack.animator().alphaValue = 1
        }
        // A slight grow from the icon's centre (the layer's anchor is its corner, hence the translations).
        guard let layer = stack.layer else { return }
        let w = stack.bounds.width / 2, h = stack.bounds.height / 2
        var start = CATransform3DMakeTranslation(w, h, 0)
        start = CATransform3DScale(start, 0.85, 0.85, 1)
        start = CATransform3DTranslate(start, -w, -h, 0)
        let grow = CABasicAnimation(keyPath: "transform")
        grow.fromValue = start
        grow.toValue = CATransform3DIdentity
        grow.duration = 0.15
        grow.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(grow, forKey: "grow")
    }

    private func fade() {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            stack.animator().alphaValue = 0
        }
    }
}
