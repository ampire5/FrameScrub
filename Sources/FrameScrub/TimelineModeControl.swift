import AppKit
import FrameScrubCore
import HomeChrome

/// The sketch's quiet three-way capsule, visible with the playback chrome over the film.
final class TimelineModeControl: NSVisualEffectView {
    var onSelect: ((TimelineFilmMode) -> Void)?
    var onSettings: (() -> Void)?
    private let segments = NSSegmentedControl()
    private let settings = NSButton()

    init() {
        super.init(frame: .zero)
        material = .hudWindow; blendingMode = .withinWindow; state = .active
        appearance = NSAppearance(named: .darkAqua)
        wantsLayer = true; layer?.cornerRadius = 12; layer?.masksToBounds = true
        let veil = NSView(); veil.wantsLayer = true
        veil.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.35).cgColor
        veil.autoresizingMask = [.width, .height]; addSubview(veil)
        segments.segmentCount = 3; segments.trackingMode = .selectOne; segments.segmentStyle = .rounded
        segments.refusesFirstResponder = true
        for (mode, symbol) in [(TimelineFilmMode.lens, "viewfinder"), (.segment, "rectangle.split.3x1"), (.overview, "arrow.left.and.right")] {
            let image = Icons.symbol(symbol, pointSize: 11, description: mode.title)
                ?? NSImage(systemSymbolName: symbol, accessibilityDescription: mode.title)
            segments.setImage(image, forSegment: mode.rawValue)
            segments.setToolTip(mode.title, forSegment: mode.rawValue)
        }
        segments.setAccessibilityLabel("Timeline view")
        segments.target = self; segments.action = #selector(selected)
        addSubview(segments); setMode(.lens)
        settings.image = Icons.symbol("slider.horizontal.3", pointSize: 11, description: "Lens settings")
            ?? NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: "Lens settings")
        settings.isBordered = false; settings.contentTintColor = .white
        settings.refusesFirstResponder = true; settings.toolTip = "Lens settings"
        settings.setAccessibilityLabel("Lens settings")
        settings.target = self; settings.action = #selector(openSettings); addSubview(settings)
    }
    required init?(coder: NSCoder) { fatalError("not used") }
    func setMode(_ mode: TimelineFilmMode) { segments.selectedSegment = mode.rawValue }
    @objc private func selected() {
        if let mode = TimelineFilmMode(rawValue: segments.selectedSegment) { onSelect?(mode) }
    }
    @objc private func openSettings() { onSettings?() }
    override func layout() {
        super.layout()
        segments.controlSize = bounds.height < 24 ? .mini : .small
        let buttonWidth: CGFloat = bounds.height < 24 ? 20 : 25
        segments.frame = NSRect(x: 2, y: 1, width: max(1, bounds.width - buttonWidth - 4), height: bounds.height - 2)
        for i in 0..<3 { segments.setWidth(max(1, (segments.frame.width - 2) / 3), forSegment: i) }
        settings.frame = NSRect(x: bounds.width - buttonWidth - 1, y: 1, width: buttonWidth, height: bounds.height - 2)
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        alphaValue > 0.01 ? super.hitTest(point) : nil
    }
}
