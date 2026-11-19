import AppKit
import HomeChrome
import InfoPanelKit

/// A focused time or frame jump. Keep the input in place when it needs correcting.
final class GoToField: NSView, NSTextFieldDelegate {
    let textField = NSTextField()
    /// Returns a correction to display, or nil when the jump was accepted.
    var onSubmit: ((String) -> String?)?
    var onClose: (() -> Void)?
    private let heading = NSTextField(labelWithString: "")
    private let hint = NSTextField(wrappingLabelWithString: "")
    private var instructions = ""

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        isHidden = true
        Chrome.Palette.overMedia.apply(to: self)
        let backdrop = GlassBackdrop(cornerRadius: 12)
        backdrop.autoresizingMask = [.width, .height]
        addSubview(backdrop)
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        heading.textColor = Chrome.Palette.overMedia.text
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = Chrome.Palette.overMedia.secondaryText
        hint.maximumNumberOfLines = 2
        textField.bezelStyle = .roundedBezel
        textField.font = .monospacedDigitSystemFont(ofSize: 17, weight: .medium)
        textField.textColor = Chrome.Palette.overMedia.text
        textField.cell?.isScrollable = true
        textField.delegate = self
        for view in [heading, textField, hint] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            heading.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            textField.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 6),
            hint.topAnchor.constraint(equalTo: textField.bottomAnchor, constant: 6),
            hint.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
        ] + [heading, textField, hint].flatMap { view in
            [view.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
             view.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14)]
        })
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Opens with `text` selected, so typing replaces it.
    func open(with text: String, allowsFrames: Bool) {
        heading.stringValue = allowsFrames ? "Go to time or frame" : "Go to time"
        instructions = allowsFrames ? "Try 1:23.5 or f1234. Press Return to jump." : "Try 1:23.5. Press Return to jump."
        textField.setAccessibilityLabel(heading.stringValue)
        showHint(instructions)
        textField.stringValue = text
        isHidden = false
        window?.makeFirstResponder(textField)
        textField.currentEditor()?.selectAll(nil)
    }

    func close() {
        guard !isHidden else { return }
        isHidden = true
        onClose?()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            if let correction = onSubmit?(textField.stringValue) {
                showHint(correction, isError: true)
                NSAccessibility.post(element: NSApplication.shared, notification: .announcementRequested,
                                     userInfo: [.announcement: correction, .priority: NSAccessibilityPriorityLevel.high.rawValue])
            } else {
                close()
            }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            close()
            return true
        default:
            return false
        }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        close()   // focus went elsewhere (a click on the video, another window)
    }

    func controlTextDidChange(_ notification: Notification) {
        if hint.stringValue != instructions { showHint(instructions) }
    }

    private func showHint(_ text: String, isError: Bool = false) {
        hint.stringValue = text
        hint.textColor = isError ? Chrome.Palette.overMedia.text : Chrome.Palette.overMedia.secondaryText
        textField.setAccessibilityHelp(text)
    }
}
