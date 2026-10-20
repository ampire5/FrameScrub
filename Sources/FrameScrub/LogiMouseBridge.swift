import AppKit
import FrameScrubCore
import LogiHIDPP
import os

/// FrameScrub's one `LogiMouse` (mouse spec §3.2, §4.4, §8): the bound `MX_*` buttons diverted while FrameScrub is in
/// front, the side buttons watched or taken by `mx-side-buttons`, Precision Scroll when the player wants it, the
/// mouse's haptic strength and panel force from `framescrub.conf`, and the haptic patterns. Made by `AppDelegate`
/// once the first window is up (only the primary instance), so the mouse search stays off the launch path. Without a
/// Logitech mouse the package stays silent: nothing arrives, nothing fails.
@MainActor final class LogiMouseBridge {
    /// A button the mouse reports, diverted or watched: the button, pressed (true) or released, and the time on
    /// NSEvent's clock (`systemUptime`, taken on delivery). The receiver runs it through `SideButtonFilter`.
    var onButton: ((MouseButton, _ pressed: Bool, TimeInterval) -> Void)?
    /// The vertical wheel went into high resolution (true) or out of it, by FrameScrub or by the user's own setting.
    var onHighResolution: ((Bool) -> Void)?
    /// The wheel's SmartShift mode changed: the mouse said so, and `byButton` when the user pressed the SmartShift
    /// button while a mode was wanted (the package has already adopted that mode as the wanted one).
    var onWheelMode: ((WheelMode, _ byButton: Bool) -> Void)?

    private let mouse: LogiMouse
    private static let log = Logger(subsystem: "local.framescrub", category: "Mouse")
    /// What `apply` last sent, so a reload that changes nothing writes nothing.
    private var applied: (divert: Set<UInt16>, watch: Set<UInt16>)?
    private var appliedHapticStrength: Int?
    private var panelForce = PanelForceSetting.keep

    /// The back and forward buttons' control IDs (`mx-side-buttons=watch|take`).
    private static let sideCIDs = Set(MouseButton.allCases.compactMap(\.sideCID))

    init(config: Config, map: InputMap) {
        mouse = LogiMouse()
        apply(config: config, map: map)   // before start(): the startup release covers what is wanted
        mouse.start()
        mouse.follow(app: NSApp)
        Task { @MainActor [weak self] in
            guard let events = self?.mouse.events else { return }
            for await event in events {
                guard let self else { return }
                handle(event)
            }
        }
    }

    /// The side buttons' control IDs the mouse is confirmed to report itself right now: their AppKit events are
    /// dropped (`SideButtonFilter`). Empty while inactive or without a Logitech mouse.
    var watching: Set<UInt16> { Set(mouse.watching.map(\.rawValue)) }

    /// Whether the vertical wheel is in high resolution now.
    var isHighResolution: Bool { mouse.isHighResolution }

    /// After a reload of input.conf or framescrub.conf: diverts what the layout binds plus, with
    /// `mx-side-buttons=take`, the side buttons, and watches them with `watch`; writes `haptic-strength` and
    /// `mx-panel-force` when they changed (Loupe's `applyMouseSettings`).
    func apply(config: Config, map: InputMap) {
        let side = config.mxSideButtons
        let wanted = (divert: map.divertedCIDs.union(side == .take ? Self.sideCIDs : []),
                      watch: side == .watch ? Self.sideCIDs : [])
        if applied.map({ $0.divert != wanted.divert || $0.watch != wanted.watch }) ?? true {
            applied = wanted
            Self.log.info("divert \(Self.hex(wanted.divert), privacy: .public) watch \(Self.hex(wanted.watch), privacy: .public)")
            mouse.divert(Set(wanted.divert.map(CID.init(rawValue:))))
            mouse.watch(Set(wanted.watch.map(CID.init(rawValue:))))
        }
        if let strength = config.hapticStrength, strength != appliedHapticStrength {
            appliedHapticStrength = strength
            Self.log.info("haptic strength \(strength)")
            mouse.setHapticStrength(UInt8(strength))   // Config holds it to 0…100
        }
        panelForce = config.mxPanelForce
        applyPanelForce()
    }

    /// Precision Scroll wanted (the pointer is over the video of the active key window, `wheel-precision=yes`).
    func wantHighResolutionWheel(_ on: Bool) { mouse.wantHighResolutionWheel(on) }

    /// Reads the wheel mode again: the mouse may have slept, reconnected or had its mode rewritten.
    func recheckHighResolutionWheel() { mouse.recheckHighResolutionWheel() }

    /// The wheel mode wanted while the player is in front; nil gives the mouse its own mode back.
    func wantWheelMode(_ mode: WheelMode?) { mouse.wantWheelMode(mode) }

    /// Reads the wheel mode again: another app may have set its own just after FrameScrub came in front.
    func recheckWheelMode() { mouse.recheckWheelMode() }

    /// Plays `event`'s pattern (`haptic-<event>`) unless `mouse-haptics=no` or the pattern is `none`; a `strong` one
    /// at `haptic-strong-strength`, the rest at the mouse's normal strength. Silent while FrameScrub is not in front.
    func play(_ event: HapticEvent, config: Config) {
        guard config.mouseHaptics, let choice = config.haptics.choice(for: event) else { return }
        mouse.play(haptic: choice.pattern, strength: choice.strong ? UInt8(config.hapticStrongStrength) : nil)
    }

    /// `mx-panel-force` over the range the mouse reported: nothing before the mouse is set up (again on `.connected`),
    /// for `keep`, for a force that cannot change, or when the mouse already has that value.
    private func applyPanelForce() {
        guard let force = mouse.panelForce, force.info.changeable,
              let value = panelForce.value(range: force.info.range, defaultValue: force.info.defaultValue),
              value != force.current else { return }
        Self.log.info("panel force \(force.current) -> \(value) (\(self.panelForce.text, privacy: .public))")
        mouse.setPanelForce(value)
    }

    /// Times are taken on delivery, on NSEvent's clock: the package's clock may be another.
    private func handle(_ event: MouseEvent) {
        let now = ProcessInfo.processInfo.systemUptime
        switch event {
        case let .pressed(cid, _):
            if let button = MouseButton(cid: cid.rawValue) { onButton?(button, true, now) }
        case let .released(cid, _):
            if let button = MouseButton(cid: cid.rawValue) { onButton?(button, false, now) }
        case .thumbWheel:
            break   // never diverted: the side wheel goes through macOS as WHEEL_LEFT / WHEEL_RIGHT
        case .connected:
            Self.log.info("connected")
            applyPanelForce()
        case .disconnected:
            Self.log.info("disconnected")
        case let .highResolutionWheel(on):
            Self.log.info("high-resolution wheel \(on ? "on" : "off", privacy: .public)")
            onHighResolution?(on)
        case let .wheelMode(mode, byButton):
            let name = mode == .freeSpin ? "free spin" : "ratchet"
            Self.log.info("wheel mode \(name, privacy: .public)\(byButton ? " (button)" : "", privacy: .public)")
            onWheelMode?(mode, byButton)
        }
    }

    private static func hex(_ cids: Set<UInt16>) -> String {
        "[" + cids.sorted().map { String(format: "0x%04x", $0) }.joined(separator: ", ") + "]"
    }
}
