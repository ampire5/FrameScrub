import AppKit
import InfoPanelKit

/// Text overlay (the OSD) on a rounded glass backdrop. Takes clicks only while `onClick` is set.
final class OverlayView: NSView {
    private let label = NSTextField(wrappingLabelWithString: "")
    private var hideWork: DispatchWorkItem?

    var fontSize: CGFloat {
        get { label.font?.pointSize ?? 12 }
        set { label.font = .monospacedDigitSystemFont(ofSize: newValue, weight: .medium) }
    }

    init(fontSize: CGFloat) {
        super.init(frame: .zero)
        wantsLayer = true
        let backdrop = GlassBackdrop(cornerRadius: 10)
        backdrop.autoresizingMask = [.width, .height]   // follows the label-sized overlay
        addSubview(backdrop)
        label.font = .monospacedDigitSystemFont(ofSize: fontSize, weight: .medium)
        label.textColor = .white
        label.preferredMaxLayoutWidth = 900   // gives the wrapping label a width, so the overlay's size is not ambiguous
        label.translatesAutoresizingMaskIntoConstraints = false
        for orientation in [NSLayoutConstraint.Orientation.horizontal, .vertical] {   // the text, not the glass, sizes the overlay
            label.setContentHuggingPriority(.init(999), for: orientation)
            label.setContentCompressionResistancePriority(.init(999), for: orientation)
        }
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])
        alphaValue = 0
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var onClick: (() -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? {
        onClick != nil && alphaValue > 0.01 && frame.contains(point) ? self : nil
    }

    override func mouseDown(with event: NSEvent) { onClick?() }

    /// Shows `text`; fades out after `duration` seconds, or stays when `duration` is nil.
    func show(_ text: String, duration: Double?) {
        label.stringValue = text
        alphaValue = 1
        hideWork?.cancel()
        guard let duration else { return }
        let work = DispatchWorkItem { [weak self] in
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.3
                self?.animator().alphaValue = 0
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    /// The text on screen, or nil while hidden or fading out.
    var visibleText: String? { alphaValue > 0.99 ? label.stringValue : nil }

    func hide() {
        hideWork?.cancel()
        alphaValue = 0
    }
}
