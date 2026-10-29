import AppKit
import FrameScrubCore
import LogiHIDPP
import MouseClient
import MouseContract
import os

/// FrameScrub's Logitech mouse, through MouseService (mouse spec §3.2, §4.4, §8; MouseService's core spec): the bound
/// `MX_*` buttons diverted while FrameScrub is in front, the side buttons watched or taken by `mx-side-buttons`, the
/// wheel mode and Precision Scroll as areas of the player window, and the haptic patterns. The service decides when
/// FrameScrub owns the buttons (in front) and which window's wheel wishes apply (under the pointer); the haptic
/// strength and the panel force are its own settings. Made by `AppDelegate` once the first window is up (only the
/// primary instance). Without the service the mouse is an ordinary one: nothing arrives, nothing fails.
@MainActor final class LogiMouseBridge {
    /// A button the mouse reports, diverted or watched: the button, pressed (true) or released, and the time on
    /// NSEvent's clock (`systemUptime`, the service's). The receiver runs it through `SideButtonFilter`.
    var onButton: ((MouseButton, _ pressed: Bool, TimeInterval) -> Void)?
    /// The vertical wheel went into high resolution (true) or out of it, by FrameScrub or by the user's own setting.
    var onHighResolution: ((Bool) -> Void)?
    /// The wheel's SmartShift mode as the mouse reports it over FrameScrub's window; `byButton` when the user pressed
    /// the SmartShift button while a mode was wanted.
    var onWheelMode: ((LogiHIDPP.WheelMode, _ byButton: Bool) -> Void)?
    /// The SmartShift button, while taken over (`takeSmartShift`): pressed (true) or released, at NSEvent's time. The
    /// mouse then leaves the wheel mode alone: a short press is FrameScrub's to switch (`SmartShiftPress`).
    var onSmartShift: ((_ pressed: Bool, TimeInterval) -> Void)?

    private let client = MouseClient()
    private static let log = Logger(subsystem: "local.framescrub", category: "Mouse")
    /// What the layout and `mx-side-buttons` want (`apply`), before the SmartShift button is added.
    private var wantedByConfig: (divert: Set<UInt16>, watch: Set<UInt16>) = ([], [])
    /// The SmartShift button is diverted: FrameScrub sets the wheel mode now (`takeSmartShift`).
    private var takesSmartShift = false
    /// The player window's wheel areas (`wantWheel`).
    private var wheel: [WheelWish] = []
    private var lastHighResolution = false

    /// The side buttons' control IDs (`mx-side-buttons=watch|take`).
    private static let sideCIDs = Set(MouseButton.allCases.compactMap(\.sideCID))

    init(config: Config, map: InputMap) {
        client.onButton = { [weak self] cid, pressed, time in
            guard let self else { return }
            if cid == CID.smartShift.rawValue {
                onSmartShift?(pressed, time)
            } else if let button = MouseButton(cid: cid) {
                onButton?(button, pressed, time)
            }
        }
        client.onWheel = { [weak self] highResolution, mode, byButton in
            guard let self else { return }
            if highResolution != lastHighResolution {
                lastHighResolution = highResolution
                Self.log.info("high-resolution wheel \(highResolution ? "on" : "off", privacy: .public)")
                onHighResolution?(highResolution)
            }
            if let mode = mode.flatMap({ LogiHIDPP.WheelMode(rawValue: $0.rawValue) }) {
                onWheelMode?(mode, byButton)
            }
        }
        client.onAvailability = { Self.log.info("MouseService \($0 ? "connected" : "not available", privacy: .public)") }
        apply(config: config, map: map)   // the first wish goes with the hello
        client.start()
    }

    /// The side buttons' control IDs the mouse is confirmed to report itself right now: their AppKit events are
    /// dropped (`SideButtonFilter`). Empty while FrameScrub is not the owner or without the service.
    var watching: Set<UInt16> { client.watching }

    /// Whether the vertical wheel is in high resolution now (as last reported over FrameScrub's window).
    var isHighResolution: Bool { client.wheel.highResolution }

    /// After a reload of input.conf or framescrub.conf: diverts what the layout binds plus, with
    /// `mx-side-buttons=take`, the side buttons, and watches them with `watch`.
    func apply(config: Config, map: InputMap) {
        let side = config.mxSideButtons
        wantedByConfig = (divert: map.divertedCIDs.union(side == .take ? Self.sideCIDs : []),
                          watch: side == .watch ? Self.sideCIDs : [])
        sendWant()
    }

    /// While FrameScrub sets the wheel mode (the player in front, `wheel-precision=yes`) it takes the SmartShift button
    /// too: a long press switches the mouse profile, a short one the wheel (`SmartShiftPress`). Elsewhere the button is
    /// the mouse's own again.
    func takeSmartShift(_ on: Bool) {
        guard on != takesSmartShift else { return }
        takesSmartShift = on
        sendWant()
    }

    /// The wheel over the player window: `mode` over all of it, and Precision Scroll inside `highResolutionRect`
    /// (window coordinates). No window or no mode: nothing asked, the mouse keeps its own mode.
    func wantWheel(window: Int?, mode: LogiHIDPP.WheelMode?, highResolutionRect: CGRect?) {
        var wishes: [WheelWish] = []
        if let window, let mode = mode.flatMap({ MouseContract.WheelMode(rawValue: $0.rawValue) }) {
            wishes = [WheelWish(window: window, mode: mode)]
            if let rect = highResolutionRect {
                wishes.append(WheelWish(window: window, rects: [rect], highResolution: true))
            }
        }
        guard wishes != wheel else { return }
        wheel = wishes
        sendWant()
    }

    /// Plays `event`'s pattern (`haptic-<event>`) unless `mouse-haptics=no` or the pattern is `none`; a `strong` one
    /// at `haptic-strong-strength`, the rest at the mouse's normal strength. Silent while FrameScrub is not in front.
    func play(_ event: HapticEvent, config: Config) {
        guard config.mouseHaptics, let choice = config.haptics.choice(for: event) else { return }
        client.play(pattern: choice.pattern.rawValue, strength: choice.strong ? UInt8(config.hapticStrongStrength) : nil)
    }

    private func sendWant() {
        let divert = wantedByConfig.divert.union(takesSmartShift ? [CID.smartShift.rawValue] : [])
        client.want(Want(divert: divert, watch: wantedByConfig.watch, thumbWheel: false, wheel: wheel))
    }
}
