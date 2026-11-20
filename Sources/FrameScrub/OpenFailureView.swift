import AppKit

/// Recovery actions and diagnostics for a file or scene that could not open.
final class OpenFailureView: NSView {
    var onRetry: (() -> Void)?
    var onOpen: (() -> Void)?
    var onBack: (() -> Void)?

    private let title = NSTextField(labelWithString: "Couldn’t open video")
    private let file = NSTextField(labelWithString: "")
    private let reason = NSTextField(wrappingLabelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let retry = NSButton(title: "Try Again", target: nil, action: nil)
    private let open = NSButton(title: "Open Another…", target: nil, action: nil)
    private let back = NSButton(title: "Back", target: nil, action: nil)

    override init(frame: NSRect) {
        super.init(frame: frame)
        appearance = NSAppearance(named: .darkAqua)   // over the black video area, whatever the system's
        wantsLayer = true
        layer?.backgroundColor = NSColor(srgbRed: 0.07, green: 0.07, blue: 0.075, alpha: 1).cgColor
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        file.font = .systemFont(ofSize: 13, weight: .medium)
        file.lineBreakMode = .byTruncatingMiddle
        reason.font = .systemFont(ofSize: 13)
        reason.maximumNumberOfLines = 3
        reason.textColor = .secondaryLabelColor
        detail.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        detail.textColor = .secondaryLabelColor
        detail.isSelectable = true
        detail.maximumNumberOfLines = 2
        detail.lineBreakMode = .byTruncatingMiddle
        for field in [title, file, reason, detail] {
            field.alignment = .center
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        retry.target = self; retry.action = #selector(retryClicked)
        retry.keyEquivalent = "\r"
        retry.toolTip = "Try again (Return)"
        open.target = self; open.action = #selector(openClicked)
        open.toolTip = "Open another video (⌘O)"
        back.target = self; back.action = #selector(backClicked)
        back.toolTip = "Go back (⌘W)"
        let actions = NSStackView(views: [back, open, retry])
        actions.spacing = 8
        let stack = NSStackView(views: [title, file, reason, detail, actions])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.setCustomSpacing(4, after: reason)
        stack.setCustomSpacing(16, after: detail)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        let preferredWidth = stack.widthAnchor.constraint(equalToConstant: 480)
        preferredWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            preferredWidth,
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -32),
        ] + [title, file, reason, detail].map { $0.widthAnchor.constraint(equalTo: stack.widthAnchor) })
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(file name: String, reason: String, detail: String?, backTitle: String) {
        file.stringValue = name
        file.toolTip = name
        self.reason.stringValue = reason
        self.detail.stringValue = detail ?? ""
        self.detail.toolTip = detail
        self.detail.isHidden = detail?.isEmpty ?? true
        back.title = backTitle
    }

    @objc private func retryClicked() { onRetry?() }
    @objc private func openClicked() { onOpen?() }
    @objc private func backClicked() { onBack?() }
}
