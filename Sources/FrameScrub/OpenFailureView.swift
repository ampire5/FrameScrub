import AppKit

/// Why a file did not open, in its place over the video: the title, the reason, the path or error in small type, and
/// the keys that lead on. It stays until another file opens, ⌘W, or Home is shown; Return tries the file again.
final class OpenFailureView: NSView {
    private let title = NSTextField(labelWithString: "")
    private let reason = NSTextField(wrappingLabelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let hints = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        appearance = NSAppearance(named: .darkAqua)   // over the black video area, whatever the system's
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        reason.font = .systemFont(ofSize: 13)
        reason.textColor = .secondaryLabelColor
        detail.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        detail.textColor = .tertiaryLabelColor
        detail.isSelectable = true   // a path to copy
        hints.font = .systemFont(ofSize: 12)
        hints.textColor = .tertiaryLabelColor
        hints.maximumNumberOfLines = 0
        for field in [title, reason, detail, hints] { field.alignment = .center }
        let stack = NSStackView(views: [title, reason, detail, hints])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.setCustomSpacing(18, after: detail)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -64),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 560),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(title: String, reason: String, detail: String?, hints: [String]) {
        self.title.stringValue = title
        self.reason.stringValue = reason
        self.detail.stringValue = detail ?? ""
        self.detail.isHidden = detail?.isEmpty ?? true
        self.hints.stringValue = hints.joined(separator: "\n")
    }
}
