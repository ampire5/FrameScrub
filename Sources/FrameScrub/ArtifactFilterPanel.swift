import AppKit
import FrameScrubCore

/// Compact controls for the existing shared slot host. Built once; no renderer or settings ownership.
@MainActor final class ArtifactFilterPanelView: NSView, NSTextFieldDelegate {
    var settings: () -> ArtifactFilterSettings = { .init() }
    var update: ([String], (inout ArtifactFilterSettings) -> Void) -> Void = { _, _ in }
    private let enabled = NSButton(checkboxWithTitle: "Filters on  ·  N", target: nil, action: nil)
    private let deband = NSPopUpButton()
    private let grain = NSPopUpButton()
    private let note = NSTextField(wrappingLabelWithString: "")
    private var sliders: [(NSSlider, NSTextField, (ArtifactFilterSettings) -> Double)] = []
    private var built = false
    private static let modes = ["Off", "Four samples", "Two passes", "Adaptive samples", "libplacebo logic", "Adaptive window — recommended"]
    private static let notes = [
        "Debanding is off. Edge, colour and grain settings remain independent.",
        "Four distant samples, accepted only when colours are close. Simple comparison mode; no explicit texture protection.",
        "Two successive four-sample passes. Stronger smoothing, with more risk of losing weak texture.",
        "Four samples with a local colour/luminance texture guard. Conservative alternative for fine detail.",
        "Adaptation of libplacebo's thresholded sampling, not identical mpv output. Its starting threshold is 0.765, radius 16; use the button below. No explicit texture guard.",
        "Recommended starting point. Shrinks the sampling window near colour changes and protects local texture. Smoother broad gradients; weak real texture can still be lost. Start at strength 0.5, threshold 9, radius 24."
    ]
    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 340, height: 620))
        appearance = NSAppearance(named: .darkAqua)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func prepare() {
        if !built { built = true; build() }
        refresh()
    }
    /// AppKit's field editor is shared with the window; its delegate owns the edited field.
    var isEditingText: Bool {
        guard let editor = window?.firstResponder as? NSTextView else { return false }
        if editor.isDescendant(of: self) { return true }
        guard let owner = editor.delegate as? NSView else { return false }
        return owner === self || owner.isDescendant(of: self)
    }
    private func label(_ value: String) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: value)
        field.textColor = NSColor(srgbRed: 242/255, green: 242/255, blue: 247/255, alpha: 1)
        field.font = .systemFont(ofSize: 12)
        return field
    }
    private func build() {
        let stack = NSStackView()
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        // The shared slot capsule overlays the top of its page. Keep the first control below it.
        stack.edgeInsets = NSEdgeInsets(top: 60, left: 16, bottom: 16, right: 16)
        enabled.target = self; enabled.action = #selector(toggle)
        stack.addArrangedSubview(enabled)
        let presets = NSStackView(views: [
            NSButton(title: "Mild cleanup", target: self, action: #selector(mildCleanup)),
            NSButton(title: "Strong cleanup", target: self, action: #selector(strongCleanup))
        ])
        presets.distribution = .fillEqually
        stack.addArrangedSubview(presets)
        addChoice("Compare", ["Processed", "Bypass", "Original left / processed right", "Changed pixels"], "artifact-compare",
                  { ArtifactFilterSettings.Comparison.allCases.firstIndex(of: $0.comparison)! },
                  { $0.comparison = ArtifactFilterSettings.Comparison.allCases[$1] }, stack)
        addSlider("Overall effect", "artifact-strength", 1, { $0.strength }, { $0.strength = $1 }, stack)
        stack.addArrangedSubview(label("DEBANDING  ·  BEFORE UPSCALING"))
        deband.addItems(withTitles: Self.modes); deband.target = self; deband.action = #selector(pickDeband)
        stack.addArrangedSubview(deband)
        note.textColor = .secondaryLabelColor; note.font = .systemFont(ofSize: 11)
        stack.addArrangedSubview(note)
        let defaults = NSButton(title: "Use starting settings for this algorithm", target: self, action: #selector(startingSettings))
        defaults.bezelStyle = .rounded; defaults.font = .systemFont(ofSize: 11)
        stack.addArrangedSubview(defaults)
        addSlider("Deband strength", "artifact-deband-strength", 1, { $0.debandStrength }, { $0.debandStrength = $1 }, stack)
        addSlider("Threshold · adaptive / window / libplacebo", "artifact-deband-threshold", 32, { $0.debandThreshold }, { $0.debandThreshold = $1 }, stack, minimum: 0.1)
        addSlider("Radius · input pixels", "artifact-deband-radius", 64, { $0.debandRadius }, { $0.debandRadius = $1 }, stack, minimum: 1)
        addSlider("Iterations · libplacebo only", "artifact-deband-iterations", 4, { Double($0.debandIterations) }, { $0.debandIterations = Int($1.rounded()) }, stack, minimum: 1)
        addSlider("Texture protection · adaptive / window", "artifact-texture-protection", 1, { $0.textureProtection }, { $0.textureProtection = $1 }, stack)
        stack.addArrangedSubview(label("COLOUR NOISE  ·  BEFORE UPSCALING"))
        addChoice("Colour filter", ["Off", "Bilateral 3×3", "Bilateral 5×5 · stronger", "Median 3×3"], "artifact-chroma",
                  { ArtifactFilterSettings.Chroma.allCases.firstIndex(of: $0.chroma)! },
                  { $0.chroma = ArtifactFilterSettings.Chroma.allCases[$1] }, stack)
        addSlider("Colour noise", "artifact-chroma-strength", 1, { $0.chroma == .off ? 0 : $0.chromaStrength }, {
            $0.chroma = $1 == 0 ? .off : ($0.chroma == .off ? .bilateral : $0.chroma); $0.chromaStrength = $1
        }, stack, extraKeys: ["artifact-chroma"])
        stack.addArrangedSubview(label("EDGES / HALOS  ·  AFTER UPSCALING"))
        addChoice("Edge filter", ["Off", "MetalFX luma limit", "MetalFX coherent edges", "Directional cleanup"], "artifact-antiring",
                  { ArtifactFilterSettings.Antiring.allCases.firstIndex(of: $0.antiring)! },
                  { $0.antiring = ArtifactFilterSettings.Antiring.allCases[$1] }, stack)
        addSlider("MetalFX edge cleanup", "artifact-antiring-strength", 1, { $0.antiring == .off ? 0 : $0.antiringStrength }, {
            $0.antiring = $1 == 0 ? .off : ($0.antiring == .off ? .edge : $0.antiring); $0.antiringStrength = $1
        }, stack, extraKeys: ["artifact-antiring"])
        stack.addArrangedSubview(label("GRAIN  ·  AFTER UPSCALING / SHARPENING"))
        grain.addItems(withTitles: ["Grain off", "White / comparison", "Fine", "Soft", "AV1-style", "Particles"])
        grain.target = self; grain.action = #selector(pickGrain)
        stack.addArrangedSubview(grain)
        addSlider("Grain amount", "artifact-grain-amount", 12, { $0.grainAmount }, { $0.grainAmount = $1 }, stack)
        addSlider("Grain size · output pixels", "artifact-grain-size", 4, { $0.grainSize }, { $0.grainSize = $1 }, stack, minimum: 0.5)
        addSlider("Grain in initially smooth areas", "artifact-grain-base", 1, { $0.grainBase }, { $0.grainBase = $1 }, stack)
        addSlider("Grain structure protection", "artifact-grain-adaptation", 1, { $0.grainAdaptation }, { $0.grainAdaptation = $1 }, stack)
        addSlider("Output dither", "artifact-dither", 1, { $0.dither }, { $0.dither = $1 }, stack)
        stack.addArrangedSubview(label("All parameters are available here. Values are shared with Settings and saved on release / Return. Spatial filters also apply while scrubbing; HDR bypasses these SDR filters."))
        let doc = FlippedView(); doc.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false; doc.addSubview(stack)
        let scroll = NSScrollView(); scroll.drawsBackground = false; scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true; scroll.documentView = doc; scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor), scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor), stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            stack.topAnchor.constraint(equalTo: doc.topAnchor), stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor)
        ])
        for view in stack.arrangedSubviews { view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true }
    }
    private final class FlippedView: NSView { override var isFlipped: Bool { true } }
    private var edits: [(String, [String], (inout ArtifactFilterSettings, Double) -> Void)] = []
    private func addSlider(_ title: String, _ key: String, _ maximum: Double,
                           _ read: @escaping (ArtifactFilterSettings) -> Double,
                           _ edit: @escaping (inout ArtifactFilterSettings, Double) -> Void,
                           _ stack: NSStackView, extraKeys: [String] = [], minimum: Double = 0) {
        let value = NSTextField(string: "")
        value.delegate = self; value.tag = sliders.count
        value.setAccessibilityLabel(title + " value")
        value.widthAnchor.constraint(equalToConstant: 64).isActive = true
        let slider = NSSlider(value: minimum, minValue: minimum, maxValue: maximum, target: self, action: #selector(change(_:)))
        slider.isContinuous = false; slider.tag = sliders.count; slider.setAccessibilityLabel(title)
        edits.append((key, extraKeys, edit)); sliders.append((slider, value, read))
        let line = NSStackView(views: [label(title), value]); line.distribution = .fill
        stack.addArrangedSubview(line); stack.addArrangedSubview(slider)
    }
    func refresh() {
        guard built else { return }
        let s = settings()
        enabled.state = s.enabled ? .on : .off
        deband.selectItem(at: ArtifactFilterSettings.Deband.allCases.firstIndex(of: s.deband)!)
        grain.selectItem(at: ArtifactFilterSettings.Grain.allCases.firstIndex(of: s.grain)!)
        note.stringValue = Self.notes[deband.indexOfSelectedItem]
        for (popup, read, _) in choices { popup.selectItem(at: read(s)) }
        for (control, value, read) in sliders {
            control.doubleValue = read(s); value.stringValue = String(format: "%.4g", read(s))
        }
    }
    private var choices: [(NSPopUpButton, (ArtifactFilterSettings) -> Int, (inout ArtifactFilterSettings, Int) -> Void)] = []
    private var choiceKeys: [String] = []
    private func addChoice(_ title: String, _ titles: [String], _ key: String,
                           _ read: @escaping (ArtifactFilterSettings) -> Int,
                           _ edit: @escaping (inout ArtifactFilterSettings, Int) -> Void, _ stack: NSStackView) {
        let popup = NSPopUpButton(); popup.addItems(withTitles: titles); popup.tag = choices.count
        popup.target = self; popup.action = #selector(pickChoice(_:)); popup.setAccessibilityLabel(title)
        choices.append((popup, read, edit)); choiceKeys.append(key)
        stack.addArrangedSubview(label(title)); stack.addArrangedSubview(popup)
    }
    @objc private func pickChoice(_ sender: NSPopUpButton) {
        update([choiceKeys[sender.tag]]) { choices[sender.tag].2(&$0, sender.indexOfSelectedItem) }; refresh()
    }
    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, sliders.indices.contains(field.tag) else { return }
        let slider = sliders[field.tag].0
        guard let value = Double(field.stringValue.replacingOccurrences(of: ",", with: ".")), value.isFinite,
              value >= slider.minValue, value <= slider.maxValue else { refresh(); return }
        slider.doubleValue = value; change(slider)
    }
    @objc private func mildCleanup() { cleanup(strong: false) }
    @objc private func strongCleanup() { cleanup(strong: true) }
    private func cleanup(strong: Bool) {
        update(ArtifactFilterSettings.cleanupKeys) { $0.applyCleanup(strong: strong) }; refresh()
    }
    @objc private func toggle() { update(["artifact-enabled"]) { $0.enabled.toggle() }; refresh() }
    @objc private func pickDeband() { update(["artifact-deband"]) { $0.deband = ArtifactFilterSettings.Deband.allCases[deband.indexOfSelectedItem] }; refresh() }
    @objc private func pickGrain() { update(["artifact-grain"]) { $0.grain = ArtifactFilterSettings.Grain.allCases[grain.indexOfSelectedItem] }; refresh() }
    @objc private func startingSettings() {
        update(["artifact-deband-strength", "artifact-deband-threshold", "artifact-deband-radius", "artifact-deband-iterations", "artifact-texture-protection"]) {
            let reference = $0.deband == .reference
            $0.debandStrength = reference ? 1 : 0.5; $0.debandThreshold = reference ? 0.765 : 9
            $0.debandRadius = reference ? 16 : 24; $0.debandIterations = 1; $0.textureProtection = 1
        }; refresh()
    }
    @objc private func change(_ sender: NSSlider) {
        let (key, extra, edit) = edits[sender.tag]
        update([key] + extra) { edit(&$0, sender.doubleValue) }; refresh()
    }
}
