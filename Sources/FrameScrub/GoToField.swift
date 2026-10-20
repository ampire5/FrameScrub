import AppKit
import InfoPanelKit

/// The ⌘G field (backlog 4.3): a small glass box at the top of the video. Enter submits, Esc or clicking
/// elsewhere closes it; a rejected entry shakes the box and keeps it open.
final class GoToField: NSView, NSTextFieldDelegate {
    let textField = NSTextField()
    /// Returns whether the text was accepted (the field then closes).
    var onSubmit: ((String) -> Bool)?
    var onClose: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        isHidden = true
        let backdrop = GlassBackdrop(cornerRadius: 12)
        backdrop.autoresizingMask = [.width, .height]
        addSubview(backdrop)
        textField.isBordered = false
        textField.drawsBackground = false
        textField.focusRingType = .none
        textField.font = .monospacedDigitSystemFont(ofSize: 17, weight: .medium)
        textField.textColor = .white
        textField.alignment = .center
        textField.placeholderAttributedString = NSAttributedString(
            string: "1:23.5   83.4   f1234",
            attributes: [.foregroundColor: NSColor(white: 1, alpha: 0.4), .font: textField.font!])
        textField.cell?.isScrollable = true
        textField.delegate = self
        textField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(textField)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 260),
            heightAnchor.constraint(equalToConstant: 40),
            textField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            textField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            textField.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Opens with `text` selected, so typing replaces it.
    func open(with text: String) {
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
            if onSubmit?(textField.stringValue) == true { close() } else { shake() }
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

    private func shake() {
        let shake = CAKeyframeAnimation(keyPath: "transform.translation.x")
        shake.values = [0, -8, 8, -6, 6, -3, 3, 0]
        shake.duration = 0.35
        layer?.add(shake, forKey: "shake")
    }
}
