import AppKit
import FrameScrubCore

/// The mouse buttons `input.conf` binds besides the left and right ones (mouse spec §4.3, §4.4): AppKit's other-mouse
/// events and the Logitech mouse's own (`LogiMouseBridge`) go through one `SideButtonFilter` into one `ButtonGestures`,
/// and the chords that fire go to `onFire`. It owns the recogniser's one timer (run-loop mode `.common`, so it also
/// runs during menu tracking and live resize), armed at `nextDeadline` after every call.
///
/// While a bound button is held it also watches the pointer's movement wherever it goes, FrameScrub's windows (a local
/// monitor) and the rest (a global one): a drag is no press even with the pointer over a slot, outside the window, or
/// frozen (Mac Mouse Fix locks it while Back drags the Space, and the deltas still come). At rest no monitor is set.
///
/// One clock throughout: NSEvent timestamps and `ProcessInfo.systemUptime` (the timer, the bridge's events) are the
/// same uptime. `cancelAll` forgets everything in flight: the window lost focus or closed, the app went to the
/// background.
@MainActor final class MouseButtonRouter {
    /// The chords that fired, in order.
    var onFire: ([KeyChord]) -> Void = { _ in }
    /// A button with chords held to the long-press threshold: releasing now is its long press.
    var onArmed: (MouseButton) -> Void = { _ in }
    /// A button's release went through the filter (the recogniser got it): the owner of an edge drag ends it.
    var onRelease: (MouseButton) -> Void = { _ in }
    /// The side buttons' control IDs the mouse reports itself right now (`LogiMouseBridge.watching`).
    var heard: () -> Set<UInt16> = { [] }

    private var gestures: ButtonGestures
    private var filter = SideButtonFilter()
    private var timer: Timer?
    private var armedDeadline: Double?
    /// The movement monitors, set while a bound button is held (`watchMoves`).
    private var moveMonitors: [Any] = []

    /// What `gestures` was made from: a reload that changes none of it keeps the presses in flight (a panel held
    /// for `add auto-color-strength` saves framescrub.conf with each wheel step).
    private struct Source: Equatable {
        let bindings: [KeyChord: Command]
        let longPressMilliseconds: Int
        let doubleInterval: Double
    }
    private var source: Source

    init(map: InputMap, longPressMilliseconds: Int) {
        source = Source(bindings: Self.pointerBindings(map), longPressMilliseconds: longPressMilliseconds,
                        doubleInterval: NSEvent.doubleClickInterval)
        gestures = ButtonGestures(map: map, longPress: Double(longPressMilliseconds) / 1000,
                                  doubleInterval: NSEvent.doubleClickInterval)
    }

    /// The bindings a button recogniser reads: those on a mouse input; a keyboard binding changing (a plugin page's keys
    /// coming and going) must not rebuild it and drop a held button's state.
    private static func pointerBindings(_ map: InputMap) -> [KeyChord: Command] {
        map.bindings.filter { $0.key.isPointerChord }
    }

    /// After a reload of input.conf or framescrub.conf: a new recogniser when the layout, `mouse-long-press` or the
    /// system's double-click interval changed (presses in flight dropped), else nothing.
    func update(map: InputMap, longPressMilliseconds: Int) {
        let now = Source(bindings: Self.pointerBindings(map), longPressMilliseconds: longPressMilliseconds,
                         doubleInterval: NSEvent.doubleClickInterval)
        guard now != source else { return }
        source = now
        gestures = ButtonGestures(map: map, longPress: Double(longPressMilliseconds) / 1000,
                                  doubleInterval: now.doubleInterval)
        rearm()
    }

    /// The bound buttons held down now.
    var held: Set<MouseButton> { gestures.held }

    // MARK: AppKit

    /// An AppKit button down: dropped when the mouse brings that side button itself (`mx-side-buttons=watch`).
    func appKitDown(_ b: MouseButton, keys: Modifiers, rightHeld: Bool, at t: Double) {
        guard filter.down(b, heard: heard(), at: t) else { return }
        dispatch(gestures.press(b, keys: keys, rightHeld: rightHeld, at: t))
    }

    func appKitUp(_ b: MouseButton, at t: Double) {
        guard filter.up(b, heard: heard()) else { return }
        release(b, at: t)
    }

    // MARK: The Logitech mouse

    /// A press the mouse reported. `watched`: heard without taking it, so the system delivers it too;
    /// `overOwnWindow`: the window under the pointer is FrameScrub's. True when it went on to the recogniser.
    @discardableResult
    func mousePress(_ b: MouseButton, keys: Modifiers, rightHeld: Bool, at t: Double, watched: Bool,
                    overOwnWindow: Bool) -> Bool {
        guard filter.mousePress(b, at: t, watched: watched, overOwnWindow: overOwnWindow) else { return false }
        dispatch(gestures.press(b, keys: keys, rightHeld: rightHeld, at: t))
        return true
    }

    func mouseRelease(_ b: MouseButton, at t: Double) {
        guard filter.mouseRelease(b) else { return }
        release(b, at: t)
    }

    // MARK: Wheel and pointer

    /// A wheel event: the held-button modifier its chord gets ([] = none); see `ButtonGestures.wheel`.
    func wheel(hasDelta: Bool, momentum: Bool, at t: Double) -> Modifiers {
        let modifier = gestures.wheel(hasDelta: hasDelta, momentum: momentum, at: t)
        rearm()
        return modifier
    }

    /// Pointer movement in points while buttons are held (a press that drifted is a drag): from `watchMoves`.
    private func move(dx: Double, dy: Double) {
        gestures.move(dx: dx, dy: dy)
        rearm()
    }

    /// Forgets every press in flight without firing, and the filter's state.
    func cancelAll() {
        gestures.cancelAll()
        filter.reset()
        rearm()
    }

    // MARK: Private

    private func release(_ b: MouseButton, at t: Double) {
        let fired = gestures.release(b, at: t)
        onRelease(b)
        dispatch(fired)
    }

    private func dispatch(_ fired: [KeyChord]) {
        rearm()
        if !fired.isEmpty { onFire(fired) }
    }

    /// A one-shot timer at the recogniser's next deadline, replaced whenever that moves; and the movement monitors
    /// for what is held now.
    private func rearm() {
        watchMoves()
        let deadline = gestures.nextDeadline
        guard deadline != armedDeadline else { return }
        armedDeadline = deadline
        timer?.invalidate()
        timer = nil
        guard let deadline else { return }
        // A hair late, so `tick` never sees the clock just short of the deadline.
        let delay = max(0, deadline - ProcessInfo.processInfo.systemUptime) + 0.01
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// The movement monitors exist exactly while a bound button is held. An event goes either to FrameScrub (the local
    /// monitor) or to another app (the global one), so none counts twice; deltas, not places: a frozen pointer moves too.
    private func watchMoves() {
        let wanted = !gestures.held.isEmpty
        guard wanted == moveMonitors.isEmpty else { return }
        guard wanted else {
            moveMonitors.forEach(NSEvent.removeMonitor)
            moveMonitors = []
            return
        }
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        let local = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated { self?.move(dx: Double(event.deltaX), dy: Double(event.deltaY)) }
            return event
        }
        let global = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated { self?.move(dx: Double(event.deltaX), dy: Double(event.deltaY)) }
        }
        moveMonitors = [local, global].compactMap { $0 }
    }

    private func tick() {
        timer = nil
        armedDeadline = nil   // armed again below while something is still pending
        let due = gestures.tick(at: ProcessInfo.processInfo.systemUptime)
        dispatch(due.fires)
        due.armed.forEach(onArmed)
    }
}
