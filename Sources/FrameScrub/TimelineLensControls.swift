import AppKit
import FrameScrubCore

/// One retained native dropdown panel. Geometry controls never change the fixed sample grid.
final class TimelineLensControls: NSViewController {
    var onChange: ((Double, Double, Double, Double, Double) -> Void)?
    var onHeightChange: ((Double) -> Void)?
    private let height = NSSlider(value: 48, minValue: 36, maxValue: 96, target: nil, action: nil)
    private let magnify = NSSlider(value: 2.75, minValue: 1, maxValue: 3.8, target: nil, action: nil)
    private let focus = NSSlider(value: 0.3, minValue: 0.08, maxValue: 0.75, target: nil, action: nil)
    private let density = NSSlider(value: 2.75, minValue: 0.5, maxValue: 4, target: nil, action: nil)
    private let crop = NSSlider(value: 0.7, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let seconds = NSSlider(value: 0, minValue: -1, maxValue: log10(30), target: nil, action: nil)
    private let values = (0..<6).map { _ in NSTextField(labelWithString: "") }
    private var mode = TimelineFilmMode.lens

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 426))
        view.appearance = NSAppearance(named: .darkAqua)
        let heading = NSTextField(labelWithString: "Filmstrip")
        heading.font = .systemFont(ofSize: 14, weight: .semibold)
        heading.frame = NSRect(x: 16, y: 398, width: 280, height: 20); view.addSubview(heading)
        let rows = [("Filmstrip height", height), ("Magnification", magnify), ("Lens area", focus), ("Outside density", density),
                    ("Thumbnail crop", crop), ("Seconds per thumbnail", seconds)]
        for (i, entry) in rows.enumerated() {
            let y = 369 - i * 56
            let label = NSTextField(labelWithString: entry.0)
            label.frame = NSRect(x: 16, y: y, width: 210, height: 18); view.addSubview(label)
            let value = values[i]
            value.alignment = .right; value.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            value.textColor = .secondaryLabelColor
            value.frame = NSRect(x: 234, y: y, width: 70, height: 18); view.addSubview(value)
            let slider = entry.1
            slider.frame = NSRect(x: 16, y: y - 25, width: 288, height: 22)
            slider.target = self; slider.action = #selector(changed(_:)); slider.isContinuous = true
            slider.setAccessibilityLabel(entry.0); view.addSubview(slider)
        }
        magnify.toolTip = "Maximum expansion at the lens centre; does not change the sampled pictures"
        density.toolTip = "Density of the film outside the lens; independent of magnification"
        height.toolTip = "Height of the thumbnail strip; hiding and pinning are separate controls"
        let hint = NSTextField(labelWithString: "⌥ + scroll changes density or step")
        hint.font = .systemFont(ofSize: 10); hint.textColor = .secondaryLabelColor
        hint.frame = NSRect(x: 16, y: 17, width: 216, height: 16); view.addSubview(hint)
        let reset = NSButton(title: "Reset", target: self, action: #selector(resetValues))
        reset.isBordered = false; reset.contentTintColor = .secondaryLabelColor
        reset.frame = NSRect(x: 235, y: 11, width: 72, height: 28); view.addSubview(reset)
        preferredContentSize = view.frame.size
        refreshLabels()
    }
    func setValues(seconds: Double, focus: Double, crop: Double, magnification: Double = 2.75,
                   density: Double = 2.75, mode: TimelineFilmMode = .lens, height: Double = 48) {
        loadViewIfNeeded(); self.mode = mode
        self.magnify.isEnabled = mode != .overview; self.focus.isEnabled = mode != .overview
        self.seconds.isEnabled = mode == .segment
        self.seconds.toolTip = mode == .segment ? "Time between fixed segment samples" : "Available in Segment view"
        self.seconds.doubleValue = log10(min(30, max(0.1, seconds)))
        self.focus.doubleValue = min(0.75, max(0.08, focus)); self.crop.doubleValue = min(1, max(0, crop))
        magnify.doubleValue = min(3.8, max(1, magnification)); self.density.doubleValue = min(4, max(0.5, density))
        self.height.doubleValue = height.isFinite ? min(96, max(36, height)) : 48
        refreshLabels()
    }
    private func refreshLabels() {
        values[0].stringValue = "\(Int(height.doubleValue.rounded())) pt"
        values[1].stringValue = String(format: "%.2g×", magnify.doubleValue)
        values[2].stringValue = "\(Int((focus.doubleValue * 100).rounded()))%"
        values[3].stringValue = String(format: "%.2g×", density.doubleValue)
        values[4].stringValue = "\(Int((crop.doubleValue * 100).rounded()))%"
        values[5].stringValue = String(format: "%.2g s", pow(10, seconds.doubleValue))
    }
    @objc private func changed(_ sender: NSSlider) {
        if sender === height { height.doubleValue = height.doubleValue.rounded() }
        refreshLabels()
        if sender === height { onHeightChange?(height.doubleValue); return }
        notifyLensChange()
    }
    private func notifyLensChange() {
        onChange?(pow(10, seconds.doubleValue), focus.doubleValue, crop.doubleValue,
                  magnify.doubleValue, density.doubleValue)
    }
    @objc private func resetValues() {
        setValues(seconds: 1, focus: 0.3, crop: 0.7, magnification: 2.75, density: 2.75, mode: mode, height: 48)
        notifyLensChange(); onHeightChange?(48)
    }
}
